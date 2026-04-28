addon.name = 'FishingInfo'
addon.author = 'InnLumin & Vavoom'
addon.version = '2.2.0'
addon.desc = 'Displays fishing catch and feeling info with sound alerts for Ashita v4.'
addon.commands = {'/fishinginfo', '/fi'};

--> Services <--
require('common')
local fonts = require('fonts')
local settings = require('settings')

--> Variables <--
local defaults = T{
    UI = T{
        Font = 'Arial',
        Size = 36,
        Position = T{ 100, 100 },
        BackgroundColor = '80000000',
    },
    Colors = T{
        Green = 'FF00FF00',
        Red = 'FFFF0000',
        Yellow = 'FFFFFF00',
        Brown = 'FF745637',
    },
    Sounds = T{
        Hook = T{ Enabled = true, File = 'Hook.wav' },
        Fail = T{ Enabled = true, File = 'Fail.wav' },
    },
    Filter = true,
    Visibility = true,
    HideWhenInactive = true,
    Fade = T{
        Enabled = true,
        Delay = 2.0,
        Duration = 1.0,
    },
}

--> Runtime state variables <--
local state = {
    Settings = settings.load(defaults),
    Font = nil,
    Active = false,
    SaveTimer = nil,
	
	-- Current display data
    CurrentFish = '',
    CurrentFishColor = 'FFFFFFFF',
    CurrentFeeling = '',
    CurrentFeelingColor = 'FFFFFFFF',
    
    -- Fade out logic variables
    FadePending = false,
    FadeStartTime = 0,
    FadeEndTime = 0,
	
    -- Render caches for font & background
    CachedBackgroundColor = nil,
    LastBackgroundColor = nil,
    LastBackgroundVisible = nil,
    LastFish = nil,
    LastFishColor = nil,
    LastFeeling = nil,
    LastFeelingColor = nil,
    LastAlpha = nil,
    LastVisible = nil,
}

local hookMessages = T{
    T{ Key = 'Large fish', Text = 'Something caught the hook!!!', Color = 'Yellow', Sound = 'Hook' },
    T{ Key = 'Small fish', Text = 'Something caught the hook!', Color = 'Green', Sound = 'Hook' },
    T{ Key = 'Item', Text = 'You feel something pulling at your line.', Color = 'Brown', Sound = 'Hook' },
    T{ Key = 'Monster', Text = 'Something clamps onto your line ferociously!', Color = 'Red', Sound = 'Hook' },
    T{ Key = 'Failed catch', Text = 'You didn\'t catch anything.', Color = 'Red', Sound = 'Fail', EndsFishing = true },
}

local feelingMessages = T{
    T{ Key = 'Good feeling', Text = 'You have a good feeling about this one!', Color = 'Green' },
    T{ Key = 'Bad feeling', Text = 'You have a bad feeling about this one.', Color = 'Yellow' },
    T{ Key = 'Terrible feeling', Text = 'You have a terrible feeling about this one...', Color = 'Red' },
    T{ Key = 'Don\'t know if you have enough skill', Text = 'You don\'t know if you have enough skill to reel this one in.', Color = 'Red' },
    T{ Key = 'Fairly sure you don\'t have enough skill', Text = 'You\'re fairly sure you don\'t have enough skill to reel this one in.', Color = 'Red' },
    T{ Key = 'Positive you don\'t have enough skill', Text = 'You\'re positive you don\'t have enough skill to reel this one in!', Color = 'Red' },
    T{ Key = 'Epic catch', Text = 'This strength... You get the sense that you are on the verge of an epic catch!', Color = 'Yellow' },
}

--> Utility helpers <--
local function log(message)
    print(string.format('\31\200[\31\05FishingInfo\31\200]\31\130 %s', message))
end

local function now()
    return os.clock()
end

local function clamp(value, minv, maxv)
    if value < minv then
        return minv
    end

    if value > maxv then
        return maxv
    end

    return value
end

local function trim(s)
    if s == nil then
        return ''
    end

    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function clean_hex_input(value)
    if value == nil then
        return nil
    end

    local c = tostring(value):gsub('^0[xX]', ''):gsub('[^%x]', ''):upper()
    if #c == 6 then
        c = 'FF' .. c
    end
    if #c == 8 then
        return c
    end
    return nil
end

local function normalize_hex_color(color, fallback)
    return clean_hex_input(color) or clean_hex_input(fallback) or 'FFFFFFFF'
end

local function invalidate_background_cache()
    state.CachedBackgroundColor = nil
    state.LastBackgroundColor = nil
    state.LastBackgroundVisible = nil
end

local function get_color(name)
    local colors = state.Settings.Colors
    if colors == nil then
        return 'FFFFFFFF'
    end

    return normalize_hex_color(colors[name], 'FFFFFFFF')
end

local function get_background_color()
    if state.CachedBackgroundColor ~= nil then
        return state.CachedBackgroundColor
    end

    local ui = state.Settings.UI
    if ui == nil then
        state.CachedBackgroundColor = '80000000'
        return state.CachedBackgroundColor
    end

    state.CachedBackgroundColor = normalize_hex_color(ui.BackgroundColor, '80000000')
    return state.CachedBackgroundColor
end

local function get_background_uint_for_alpha(alpha)
    local c = get_background_color()
    local baseAlpha = tonumber(c:sub(1, 2), 16) or 255
    local scaledAlpha = clamp(math.floor(baseAlpha * clamp(alpha or 255, 0, 255) / 255), 0, 255)
    return tonumber(string.format('%02X%s', scaledAlpha, c:sub(3)), 16) or 0x00000000
end

local function with_alpha(color, alpha)
    local c = normalize_hex_color(color, 'FFFFFFFF')
    local rgb = c:sub(3)
    local a = string.format('%02X', clamp(math.floor(alpha or 255), 0, 255))
    return a .. rgb
end

local function build_font_settings()
    local pos = state.Settings.UI.Position or T{ 0, 0 }

    return T{
        visible = state.Font and state.Font.visible or false,
        font_family = state.Settings.UI.Font or 'Arial',
        font_height = tonumber(state.Settings.UI.Size) or 36,
        color = 0xFFFFFFFF,
        position_x = tonumber(pos[1]) or 0,
        position_y = tonumber(pos[2]) or 0,
        background = T{
            visible = true,
            color = get_background_uint_for_alpha(255),
        },
    }
end

local function invalidate_text_cache()
    state.LastFish = nil
    state.LastFishColor = nil
    state.LastFeeling = nil
    state.LastFeelingColor = nil
    state.LastAlpha = nil
    state.LastVisible = nil
end

local function apply_font_settings()
    invalidate_background_cache()
    invalidate_text_cache()

    if state.Font ~= nil then
        state.Font:apply(build_font_settings())
    end
end

local function sync_position_from_font()
    if state.Font == nil then
        return
    end

    state.Settings.UI.Position[1] = state.Font.position_x or 0
    state.Settings.UI.Position[2] = state.Font.position_y or 0
end

local function set_font_background(color, visible)
    if state.Font == nil or state.Font.background == nil then
        return
    end

    if state.LastBackgroundColor == color and state.LastBackgroundVisible == visible then
        return
    end

    state.LastBackgroundColor = color
    state.LastBackgroundVisible = visible

    state.Font.background.color = color
    state.Font.background.visible = visible

    pcall(function()
        if state.Font.background ~= nil then
            state.Font.background.color = color
            state.Font.background.visible = visible
        end
    end)
end

local function cancel_fade()
    state.FadePending = false
    state.FadeStartTime = 0
    state.FadeEndTime = 0
end

local function clear_display()
    cancel_fade()
    state.Active = false
    state.CurrentFish = ''
    state.CurrentFishColor = 'FFFFFFFF'
    state.CurrentFeeling = ''
    state.CurrentFeelingColor = 'FFFFFFFF'
    invalidate_text_cache()
end

local function begin_visual_fade()
    if state.Settings.HideWhenInactive ~= true
    or state.Settings.Fade == nil
    or state.Settings.Fade.Enabled ~= true then
        clear_display()
        return
    end

    local delay = math.max(0, tonumber(state.Settings.Fade.Delay) or 0)
    local duration = math.max(0, tonumber(state.Settings.Fade.Duration) or 0)

    if delay <= 0 and duration <= 0 then
        clear_display()
        return
    end

    state.Active = false

    local t = now()
    state.FadePending = true
    state.FadeStartTime = t + delay
    state.FadeEndTime = state.FadeStartTime + duration
end

local function mark_active()
    cancel_fade()
    state.Active = true
end

local function play_alert_sound(name)
    local sounds = state.Settings.Sounds
    if sounds == nil then
        return
    end

    local sound = sounds[name]
    if sound == nil or sound.Enabled ~= true or sound.File == nil or sound.File == '' then
        return
    end

    local fullpath = string.format('%ssounds\\%s', addon.path, sound.File)
    ashita.misc.play_sound(fullpath)
end

local function extract_angler_fish(message)
    local fish = message:match('[Aa]ngler\'s.-:%s*(.+)$')

    if fish == nil and #message >= 63 then
        fish = message:sub(63)
    end

    if fish == nil then
        fish = message
    end

    fish = fish:gsub('|c%x%x%x%x%x%x%x%x|', '')
    fish = fish:gsub('|r', '')
    fish = fish:gsub('%d', '')
    fish = fish:gsub('^[%p%s]+', '')
    fish = fish:gsub('[%p%s]+$', '')
    fish = trim(fish)

    if fish == '' then
        fish = 'Unknown'
    end

    return fish
end

local function set_boolean_setting(current, value)
    if value == nil then
        return not current
    end

    value = value:lower()

    if value == 'on' or value == 'true' or value == '1' or value == 'yes' then
        return true
    end

    if value == 'off' or value == 'false' or value == '0' or value == 'no' then
        return false
    end

    return not current
end

--> Settings and events <--
settings.register('settings', 'settings_update', function (s)
    if s ~= nil then
        state.Settings = s
    end

    apply_font_settings()
end)

ashita.events.register('load', 'fishinginfo_load', function ()
    state.Font = fonts.new(build_font_settings())
    state.Font.text = ''
    set_font_background(get_background_uint_for_alpha(255), true)
    invalidate_text_cache()
end)

ashita.events.register('unload', 'fishinginfo_unload', function ()
    sync_position_from_font()
    settings.save()

    if state.Font ~= nil then
        state.Font:destroy()
        state.Font = nil
    end
end)

--> Slash command handlers <--
ashita.events.register('command', 'fishinginfo_command', function (e)
    local args = e.command:args()
    if #args == 0 then
        return
    end

    local cmd = args[1]:lower()
    if cmd ~= '/fishinginfo' and cmd ~= '/fi' then
        return
    end

    e.blocked = true

    if #args == 1 then
        state.Settings.Visibility = not state.Settings.Visibility
        settings.save()
        log(string.format('Visibility: %s', state.Settings.Visibility and '\30\02Enabled' or '\30\68Disabled'))
        return
    end

    local sub = args[2]:lower()

    if sub == 'on' then
        state.Settings.Visibility = true
        settings.save()
        log('Visibility: \30\02Enabled')
        return
    end

    if sub == 'off' then
        state.Settings.Visibility = false
        settings.save()
        log('Visibility: \30\68Disabled')
        return
    end

    if sub == 'pos' then
        if #args < 4 then
            local x = state.Font and state.Font.position_x or state.Settings.UI.Position[1] or 0
            local y = state.Font and state.Font.position_y or state.Settings.UI.Position[2] or 0
            log(string.format('Position: X:%s Y:%s', tostring(x), tostring(y)))
            return
        end

        local x = tonumber(args[3])
        local y = tonumber(args[4])

        if x == nil or y == nil then
            log('\30\68Error setting position.')
            return
        end

        state.Settings.UI.Position[1] = x
        state.Settings.UI.Position[2] = y
        apply_font_settings()
        settings.save()
        log(string.format('Position set to X:%d Y:%d', x, y))
        return
    end

    if sub == 'filter' then
        state.Settings.Filter = set_boolean_setting(state.Settings.Filter, args[3])
        settings.save()
        log(string.format('Filter: %s', state.Settings.Filter and '\30\02Enabled' or '\30\68Disabled'))
        return
    end

    if sub == 'hideinactive' or sub == 'activeeffect' then
        state.Settings.HideWhenInactive = set_boolean_setting(state.Settings.HideWhenInactive, args[3])
        settings.save()
        log(string.format('HideWhenInactive: %s', state.Settings.HideWhenInactive and '\30\02Enabled' or '\30\68Disabled'))
        return
    end

    if sub == 'fade' then
        state.Settings.Fade.Enabled = set_boolean_setting(state.Settings.Fade.Enabled, args[3])
        settings.save()
        log(string.format('Fade: %s', state.Settings.Fade.Enabled and '\30\02Enabled' or '\30\68Disabled'))
        return
    end

    if sub == 'fadedelay' then
        local value = tonumber(args[3] or '')
        if value == nil or value < 0 then
            log('\30\68Usage: /fi fadedelay <seconds>')
            return
        end

        state.Settings.Fade.Delay = value
        settings.save()
        log(string.format('Fade delay set to %.2f seconds.', value))
        return
    end

    if sub == 'fadeduration' then
        local value = tonumber(args[3] or '')
        if value == nil or value < 0 then
            log('\30\68Usage: /fi fadeduration <seconds>')
            return
        end

        state.Settings.Fade.Duration = value
        settings.save()
        log(string.format('Fade duration set to %.2f seconds.', value))
        return
    end

    if sub == 'bgcolor' then
        if args[3] == nil then
            log(string.format('BackgroundColor: %s', get_background_color()))
            return
        end

        local normalized = clean_hex_input(args[3])
        if normalized == nil then
            log('\30\68Usage: /fi bgcolor <AARRGGBB or RRGGBB>')
            return
        end

        state.Settings.UI.BackgroundColor = normalized
        invalidate_background_cache()
        apply_font_settings()
        settings.save()
        log(string.format('BackgroundColor set to %s', normalized))
        return
    end

    if sub == 'help' then
        local help = T{
            '/fi - Toggle visibility.',
            '/fi on - Show the UI.',
            '/fi off - Hide the UI.',
            '/fi pos - Print the current UI position.',
            '/fi pos <x> <y> - Set the UI position.',
            '/fi filter [on|off] - Toggle or set chat filtering.',
            '/fi hideinactive [on|off] - Toggle or set hiding while inactive.',
            '/fi fade [on|off] - Toggle or set fade-out.',
            '/fi fadedelay <seconds> - Set fade delay.',
            '/fi fadeduration <seconds> - Set fade duration.',
            '/fi bgcolor [AARRGGBB|RRGGBB] - Show or set the background color.',
        }

        for _, line in ipairs(help) do
            log(line)
        end
        return
    end

    log('Unknown command. Use /fi help')
end)

--> Fishing info detection <--
ashita.events.register('text_in', 'fishinginfo_text_in', function (e)
    if e.injected == true then
        return
    end

    local message = e.message

    for _, entry in ipairs(hookMessages) do
        if string.find(message, entry.Text, 1, true) ~= nil then
            state.CurrentFish = entry.Key
            state.CurrentFishColor = get_color(entry.Color)
            play_alert_sound(entry.Sound)

            if entry.EndsFishing == true then
                begin_visual_fade()
            else
                mark_active()
            end

            if state.Settings.Filter == true then
                e.blocked = true
            end
            return
        end
    end

    for _, entry in ipairs(feelingMessages) do
        if string.find(message, entry.Text, 1, true) ~= nil then
            mark_active()
            state.CurrentFeeling = entry.Key
            state.CurrentFeelingColor = get_color(entry.Color)

            if state.Settings.Filter == true then
                e.blocked = true
            end
            return
        end
    end

    if string.find(message:lower(), 'angler\'s', 1, true) ~= nil then
        mark_active()
        state.CurrentFeeling = 'Angler\'s Senses'
        state.CurrentFeelingColor = get_color('Green')
        state.CurrentFish = extract_angler_fish(message)
        state.CurrentFishColor = get_color('Green')

        if state.Settings.Filter == true then
            e.blocked = true
        end
        return
    end
end)

--> Outgoing /fish detection <--
ashita.events.register('text_out', 'fishinginfo_text_out', function (e)
    if e.injected == true then
        return
    end

    local message = e.message:lower()
    if message == '/fish' or string.sub(message, 1, 6) == '/fish ' then
        if state.Active == true then
            begin_visual_fade()
        elseif state.FadePending ~= true then
            clear_display()
        end
    end
end)

--> FishAid packet logic <--
ashita.events.register('packet_in', 'fishinginfo_packet_in', function (e)
    if e.id == 0x00A then
        clear_display()
        return
    end

    if e.id == 0x037 then
        if e.size >= 0x31 then
            local status = struct.unpack('B', e.data, 0x30 + 1)
            if status == 0 then
                if state.Active then
                    begin_visual_fade()
                elseif state.FadePending then
                    clear_display()
                end
            end
        end
        return
    end
end)

--> Rendering <--
ashita.events.register('d3d_present', 'fishinginfo_present', function ()
    if state.Font == nil then
        return
    end

    --> Drag to move delayed save settings <--
    if state.LastVisible == true then
        local x = state.Font.position_x or 0
        local y = state.Font.position_y or 0
        if state.Settings.UI.Position[1] ~= x or state.Settings.UI.Position[2] ~= y then
            state.Settings.UI.Position[1] = x
            state.Settings.UI.Position[2] = y
            state.SaveTimer = now() + 0.5
        end
    end

    if state.SaveTimer ~= nil and now() > state.SaveTimer then
        settings.save()
        state.SaveTimer = nil
    end
	
	--> Current frame overlay visibility <--
    local shouldShow = state.Settings.Visibility == true
    local alpha = 255

    if shouldShow then
        if state.Active == true then
            alpha = 255
        elseif state.FadePending == true then
            local t = now()

            if t < state.FadeStartTime then
                alpha = 255
            elseif state.FadeEndTime <= state.FadeStartTime then
                clear_display()
                shouldShow = false
            elseif t >= state.FadeEndTime then
                clear_display()
                shouldShow = false
            else
                local progress = (t - state.FadeStartTime) / (state.FadeEndTime - state.FadeStartTime)
                alpha = clamp(math.floor((1.0 - progress) * 255), 0, 255)
            end
        elseif state.Settings.HideWhenInactive == true then
            shouldShow = false
        else
            alpha = 255
        end
    end
	
	--> Hide UI if not showing <--
    if shouldShow ~= true then
        if state.LastVisible ~= false then
            state.Font.visible = false
            set_font_background(0x00000000, false)
            state.LastVisible = false
            state.LastAlpha = nil
            state.LastFish = nil
            state.LastFishColor = nil
            state.LastFeeling = nil
            state.LastFeelingColor = nil
        end
        return
    end

    local fish = state.CurrentFish or ''
    local fishColorRaw = state.CurrentFishColor or 'FFFFFFFF'
    local feeling = state.CurrentFeeling or ''
    local feelingColorRaw = state.CurrentFeelingColor or 'FFFFFFFF'
	
	--> Update background if needed <--
    if state.LastVisible ~= true or state.LastAlpha ~= alpha or state.LastBackgroundColor == nil then
        local backgroundColor = get_background_uint_for_alpha(alpha)
        set_font_background(backgroundColor, alpha > 0)
    end
	
	--> Check if anything changed <--
    local changed =
        state.LastVisible ~= true or
        state.LastAlpha ~= alpha or
        state.LastFish ~= fish or
        state.LastFishColor ~= fishColorRaw or
        state.LastFeeling ~= feeling or
        state.LastFeelingColor ~= feelingColorRaw
		
    if changed then
        local labelColor   = with_alpha('FFFFFFFF', alpha)
        local fishColor    = with_alpha(fishColorRaw, alpha)
        local feelingColor = with_alpha(feelingColorRaw, alpha)
		
        state.Font.visible = true
		
        if state.Settings.HideWhenInactive == true and fish ~= '' and feeling == '' then
        state.Font.text = string.format(
            '|c%s|Fish:|r |c%s|%s|r',
            labelColor,
            fishColor,
            fish
        )
    else
        state.Font.text = string.format(
            '|c%s|Fish:|r |c%s|%s|r\n|c%s|Feeling:|r |c%s|%s|r',
            labelColor,
            fishColor,
            fish,
            labelColor,
            feelingColor,
            feeling
        )
    end
		
		--> Update caches <--
        state.LastVisible = true
        state.LastAlpha = alpha
        state.LastFish = fish
        state.LastFishColor = fishColorRaw
        state.LastFeeling = feeling
        state.LastFeelingColor = feelingColorRaw
    end
end)
