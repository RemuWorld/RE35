-----------------------------------------------------------
-- History mode highlights
-----------------------------------------------------------
local function blend_rgb(
    base,
    tint,
    amount
)
    local base_r =
        math.floor(base / 0x10000) % 0x100

    local base_g =
        math.floor(base / 0x100) % 0x100

    local base_b =
        base % 0x100


    local tint_r =
        math.floor(tint / 0x10000) % 0x100

    local tint_g =
        math.floor(tint / 0x100) % 0x100

    local tint_b =
        tint % 0x100


    local function mix(
        a,
        b
    )
        return math.floor(
            a
                + (
                    b - a
                )
                * amount
                + 0.5
        )
    end


    local red =
        mix(
            base_r,
            tint_r
        )

    local green =
        mix(
            base_g,
            tint_g
        )

    local blue =
        mix(
            base_b,
            tint_b
        )


    return
        red * 0x10000
        + green * 0x100
        + blue
end


local function setup_history_highlights()
    -------------------------------------------------------
    -- History frame
    -------------------------------------------------------

    vim.api.nvim_set_hl(
        0,
        "HistoryModeFrame",
        {
            fg = "#E6A0A0",
        }
    )


    -------------------------------------------------------
    -- Undo preview
    -------------------------------------------------------

    local normal =
        vim.api.nvim_get_hl(
            0,
            {
                name = "Normal",
                link = false,
            }
        )


    local warning =
        vim.api.nvim_get_hl(
            0,
            {
                name = "DiagnosticWarn",
                link = false,
            }
        )


    local fallback_background

    local fallback_foreground


    if vim.o.background == "light" then
        fallback_background =
            0xF2F2F2

        fallback_foreground =
            0x202020
    else
        fallback_background =
            0x1E1E1E

        fallback_foreground =
            0xD4D4D4
    end


    local normal_background =
        normal.bg
        or fallback_background


    local normal_foreground =
        normal.fg
        or fallback_foreground


    local warning_foreground =
        warning.fg
        or 0xE5C07B


    local preview_background =
        blend_rgb(
            normal_background,
            warning_foreground,
            0.22
        )


    vim.api.nvim_set_hl(
        0,
        "HistoryUndoPreview",
        {
            fg = normal_foreground,
            bg = preview_background,
        }
    )


    vim.api.nvim_set_hl(
        0,
        "HistoryUndoPreviewNumber",
        {
            fg = warning_foreground,
            bold = true,
        }
    )
end


setup_history_highlights()


vim.api.nvim_create_autocmd(
    "ColorScheme",
    {
        group =
            vim.api.nvim_create_augroup(
                "HistoryModeColors",
                {
                    clear = true,
                }
            ),

        callback =
            setup_history_highlights,
    }
)
