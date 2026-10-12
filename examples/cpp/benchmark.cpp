#include "../../native/ce.h"
#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <filesystem>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>
using Clock = std::chrono::steady_clock;
static double milliseconds(Clock::time_point begin) { return std::chrono::duration<double,std::milli>(Clock::now()-begin).count(); }
static std::string call(ce_handle *h,const std::string &op,const std::string &json) {
  char *out=nullptr,*error=nullptr;size_t size=0,error_size=0;
  int status=ce_call(h,op.c_str(),json.data(),json.size(),&out,&size,&error,&error_size);
  std::string result=status==CE_OK?std::string(out,size):error?std::string(error,error_size):"Bridge failed";
  ce_free(out);ce_free(error);
  if(status!=CE_OK || result.rfind("{\"ok\":true",0)!=0)throw std::runtime_error(result);
  return result;
}
static std::string value(const std::string &reply){auto start=reply.find("\"value\":");if(start==std::string::npos)throw std::runtime_error("Missing value");return reply.substr(start+8,reply.size()-start-9);}
static std::string id(const std::string &reply){auto start=reply.find("\"request_id\":\"");if(start==std::string::npos)throw std::runtime_error("Missing request ID");start+=14;return reply.substr(start,reply.find('"',start)-start);}
int main(int argc,char **argv){
  ce_handle *handle=nullptr;
  try {
    if(argc!=4)throw std::runtime_error("usage: ce_benchmark <runtime> <lua-root> <command.json>");
    char *error=nullptr;size_t size=0;auto begin=Clock::now();
    int status=ce_create(argv[1],argv[2],&handle,&error,&size);
    std::string reason=error?std::string(error,size):"Create failed";ce_free(error);
    if(status!=CE_OK)throw std::runtime_error(reason);
    double startup=milliseconds(begin);
    std::ifstream input(std::filesystem::u8path(argv[3]),std::ios::binary);
    if(!input)throw std::runtime_error("Missing fixture");
    call(handle,"register",std::string(std::istreambuf_iterator<char>(input),{}));
    std::vector<double> times;long counter=0;
    for(int i=0;i<1100;++i){
      auto t=Clock::now();std::string target="{\"token\":\"counter\",\"revision\":\""+std::to_string(counter)+"\"}";
      std::string ticket=value(call(handle,"select","{\"id\":\"demo.increment\",\"target\":"+target+",\"capabilities\":{\"counter\":true}}"));
      std::string request=id(call(handle,"invoke","{\"selection\":"+ticket+",\"args\":{\"amount\":1},\"target\":"+target+",\"capabilities\":{\"counter\":true}}"));
      call(handle,"claim","{\"request_id\":\""+request+"\",\"target\":"+target+",\"capabilities\":{\"counter\":true}}");
      ++counter; // actual host handler, immediately after claim
      call(handle,"complete","{\"request_id\":\""+request+"\",\"completion\":{\"status\":\"succeeded\",\"result\":{\"counter\":"+std::to_string(counter)+"}}}");
      if(i>=100)times.push_back(milliseconds(t));
    }
    std::sort(times.begin(),times.end());
    std::cout<<"{\"iterations\":1000,\"calls_per_iteration\":4,\"actual_counter\":"<<counter<<",\"startup_ms\":"<<startup<<",\"median_ms\":"<<times[499]<<",\"p95_ms\":"<<times[949]<<",\"max_ms\":"<<times.back()<<"}\n";
    ce_destroy(handle);return 0;
  }catch(const std::exception &error){if(handle)ce_destroy(handle);std::cerr<<error.what()<<'\n';return 1;}
}
