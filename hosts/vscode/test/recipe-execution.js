'use strict';
// Opt-in actual checkout/CMake work through the VS Code task/recipe boundary.
// This is controlled execution, not diagnostics navigation or human timing.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { performance } = require('node:perf_hooks');

async function run({ api, root, options }) {
  let checks = 0, host;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const environment = name => {
    const value = process.env[name];
    assert(typeof value === 'string' && value !== '' && path.isAbsolute(value) && !value.includes('\0'),
      `Provide an existing absolute ${name}; this probe installs nothing`);
    return value;
  };
  const checkout = await fs.realpath(environment('RE35_RECIPE_CHECKOUT'));
  const requestedBuild = environment('RE35_RECIPE_BUILD');
  const cmake = await fs.realpath(environment('RE35_RECIPE_CMAKE'));
  const ninja = await fs.realpath(environment('RE35_RECIPE_NINJA'));
  const cc = await fs.realpath(environment('RE35_RECIPE_CC'));
  const cxx = await fs.realpath(environment('RE35_RECIPE_CXX'));
  const artifacts = await fs.realpath(path.join(checkout, '.artifacts'));
  const build = path.resolve(requestedBuild);
  const relativeBuild = path.relative(process.platform === 'win32' ? artifacts.toLowerCase() : artifacts,
    process.platform === 'win32' ? build.toLowerCase() : build);
  assert(relativeBuild !== '' && !path.isAbsolute(relativeBuild)
    && relativeBuild !== '..' && !relativeBuild.startsWith('..' + path.sep), 'Choose a new build directory inside checkout/.artifacts');
  const physicalParent = await fs.realpath(path.dirname(build));
  const relativeParent = path.relative(process.platform === 'win32' ? artifacts.toLowerCase() : artifacts,
    process.platform === 'win32' ? physicalParent.toLowerCase() : physicalParent);
  assert(!path.isAbsolute(relativeParent) && relativeParent !== '..' && !relativeParent.startsWith('..' + path.sep),
    'Build parent must physically remain inside checkout/.artifacts');
  assert(!(await fs.lstat(build).catch(error => { if (error.code === 'ENOENT') return null; throw error; })),
    'Build directory already exists; existing caches are never rewritten by this probe');
  for (const executable of [cmake, ninja, cc, cxx]) assert((await fs.stat(executable)).isFile(), 'Installed tool must exist');
  const profileFile = path.join(checkout, 'examples/re35-development.json');
  const profileBytes = await fs.readFile(profileFile);
  const data = JSON.parse(profileBytes.toString('utf8'));
  const profileSha256 = createHash('sha256').update(profileBytes).digest('hex');
  // Local fixture selection maps the logical config base; the checked-in
  // shared profile remains unchanged and contains no machine path.
  data.projects.re35_native_targets.root = { base: 'config', path: '.' };
  data.projects.re35_native_targets.targets.push('re35_intentional_missing_target');
  const validationScript = path.join(root, 'recipe-native-validate.cmake');
  const validationMarker = path.join(root, 'recipe-native-validated.txt');
  await fs.writeFile(validationScript, [
    'execute_process(COMMAND "${PROGRAM}" "${LUA_RUNTIME}" "${CORE_SOURCE}" "${COMMAND_FIXTURE}" RESULT_VARIABLE CODE OUTPUT_VARIABLE OUTPUT ERROR_VARIABLE ERROR)',
    'if(NOT CODE EQUAL 0)', '  message(FATAL_ERROR "Actual C++ host failed: ${CODE}: ${ERROR}")', 'endif()',
    'if(NOT OUTPUT MATCHES "checks PASS; actual counter=3")',
    '  message(FATAL_ERROR "Actual C++ host produced no nonempty verification: ${OUTPUT}")', 'endif()',
    'message("${OUTPUT}")', 'file(WRITE "${MARKER}" "${OUTPUT}")', ''
  ].join('\n'), { flag: 'wx' });
  const localOverrides = {
    re35_target_configure: { command: cmake, args: ['-S', '{root}', '-B', build, '-G', 'Ninja',
      '-DCMAKE_BUILD_TYPE={configuration}', '-DCMAKE_C_COMPILER=' + cc,
      '-DCMAKE_CXX_COMPILER=' + cxx, '-DCMAKE_MAKE_PROGRAM=' + ninja] },
    re35_target_build: { command: cmake, args: ['--build', build, '--target', '{target}',
      '--config', '{configuration}', '--parallel', '1'] },
    re35_target_validate: { command: cmake, args: [
      '-DPROGRAM=' + path.join(build, process.platform === 'win32' ? 'ce_cpp.exe' : 'ce_cpp'),
      '-DLUA_RUNTIME=' + options.luaRuntime, '-DCORE_SOURCE=' + options.corePath,
      '-DCOMMAND_FIXTURE=' + path.join(checkout, 'examples/command.json'),
      '-DMARKER=' + validationMarker, '-P', validationScript] }
  };
  const observations = [], memorySamples = { before_task_host: process.memoryUsage() };
  try {
    host = new api.Host({ ...options, configBase: checkout,
      toolOverrides: { ...(options.toolOverrides || {}), ...localOverrides } });
    const workflow = host.workflowService();
    const imported = await workflow.previewProfile(data);
    workflow.applyProfile(imported);
    const tasks = workflow.taskService();
    memorySamples.after_task_service = process.memoryUsage();
    const execute = async (recipeId, target, expected, expectedSteps) => {
      const choice = await workflow.prepareSelection({ projectId: 're35_native_targets', recipeId,
        configuration: 'Debug', target });
      await workflow.commitSelection(choice);
      const review = await tasks.prepareSelected();
      if (!expectedSteps) {
        eq(review.cwd, checkout, 'Actual selected checkout owns task cwd');
        eq(review.argv[0], cmake, 'Local executable is pinned without changing portable declarations');
      } else {
        eq(review.steps.map(step => step.id), expectedSteps.map(step => step[0]), 'Review preserves declared order');
        ok(review.steps.every(step => step.cwd === checkout && step.argv[0] === cmake), 'All reviewed steps retain the local checkout/executable');
      }
      eq(review.selection.configuration, 'Debug');
      eq(review.selection.target, target);
      const started = performance.now();
      const task = await tasks.start(review, { mode: 'run-saved' });
      await task.done;
      const result = task.snapshot();
      await fs.writeFile(path.join(root, `recipe-native-outcome-${observations.length + 1}.json`),
        JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
      eq(result.status, expected, 'Task records actual CMake outcome');
      eq(result.truncated, false, 'Small controlled build output is complete');
      eq(result.completionRecorded, true, 'Core records the actual terminal outcome');
      eq(result.activeStepId, null, 'Terminal parent has no active step');
      if (expectedSteps) eq(result.steps.map(step => [step.id, step.status]), expectedSteps, 'Actual outcomes preserve declaration order and skipped steps');
      if (expected === 'succeeded') eq(result.exitCode, 0);
      else ok(Number.isInteger(result.exitCode) && result.exitCode !== 0, 'Known missing target returns a real nonzero exit');
      eq(workflow.selection, choice, 'Execution leaves current logical selection intact');
      eq(await fs.readFile(profileFile), profileBytes, 'Execution never rewrites the shared profile');
      observations.push({ recipe_id: recipeId, target, argv: review.argv, cwd: review.cwd,
        status: result.status, exit_code: result.exitCode, signal: result.signal,
        output_utf8_bytes: Buffer.byteLength(result.stdout + result.stderr, 'utf8'),
        wall_ms: performance.now() - started, provenance: result.provenance,
        completion_recorded: result.completionRecorded,
        steps: result.steps.map(step => ({ id: step.id, status: step.status, argv: step.argv, cwd: step.cwd,
          exit_code: step.exitCode, stdout: step.stdout, stderr: step.stderr })) });
      memorySamples[`after_task_${observations.length}`] = process.memoryUsage();
      return result;
    };
    const configured = await execute('re35_native_target_configure', 'ce_cpp', 'succeeded');
    ok((configured.stdout + configured.stderr).includes('Build files have been written'), 'Actual CMake configuration completes');
    const cache = await fs.readFile(path.join(build, 'CMakeCache.txt'), 'utf8');
    ok(/^CMAKE_BUILD_TYPE:STRING=Debug$/m.test(cache), 'Physical CMake cache retains Debug');
    const compiled = await execute('re35_native_target_compile', 'ce_cpp', 'succeeded');
    const executable = path.join(build, process.platform === 'win32' ? 'ce_cpp.exe' : 'ce_cpp');
    ok((await fs.stat(executable)).isFile(), 'Actual RE35 C++ target exists');
    ok((compiled.stdout + compiled.stderr).length > 0, 'Actual build output is retained');
    const failed = await execute('re35_native_target_compile', 're35_intentional_missing_target', 'failed');
    ok((failed.stdout + failed.stderr).includes('re35_intentional_missing_target'), 'Actual engine explains the requested missing target');
    eq(tasks.list().length, 3, 'Three explicit executions retain three task outcomes');
    const completed = await execute('re35_native_target_build_validate', 'ce_cpp', 'succeeded',
      [['configure', 'succeeded'], ['build', 'succeeded'], ['validate', 'succeeded']]);
    ok((completed.stdout + completed.stderr).includes('checks PASS; actual counter=3'), 'Declared test step executes the actual C++ host');
    ok((await fs.readFile(validationMarker, 'utf8')).includes('checks PASS; actual counter=3'), 'Actual successful verification writes its marker');
    // The same declared recipe must stop at its failed middle build. A removed
    // fixture-owned marker distinguishes this execution from the prior success.
    await fs.unlink(validationMarker);
    await execute('re35_native_target_build_validate', 're35_intentional_missing_target', 'failed',
      [['configure', 'succeeded'], ['build', 'failed'], ['validate', 'skipped']]);
    eq(await fs.lstat(validationMarker).catch(error => { if (error.code === 'ENOENT') return null; throw error; }), null,
      'Failed middle step never starts the declared verification');
    eq(tasks.list().length, 4, 'Five executions retain only the four newest task outcomes');
    return { checks, evidence: 'actual VS Code RE35 checkout/CMake configure-build-test recipe',
      sequential_recipe_execution: true, compiler_diagnostics_navigation: false,
      physical_keys_measured: false, human_times_measured: false,
      profile_sha256: profileSha256, checkout, build, observations, memory_samples: memorySamples,
      resource_scope: 'whole ExtensionHost raw memory samples without forced GC; not attributable/retained-memory acceptance; wall samples are controlled execution durations, not UI latency' };
  } finally {
    if (host) { host.dispose(); memorySamples.after_dispose = process.memoryUsage(); }
    // The parent runner owns the isolated VS Code host and artifact build tree.
    // Successful and failed logs/cache remain available; no recursive deletion.
    assert(path.isAbsolute(root), 'Parent test root must remain an explicit isolated path');
  }
}
module.exports = { run };
