--[[
MultiUser patch for KOReader
File: koreader/patches/1-multiuser.lua
--]]

local lfs = require("libs/libkoreader-lfs")

local function loadLuaTable(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local fn = load("return " .. content)
    if not fn then return nil end
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function saveLuaTable(path, tbl)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("{\n")
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            f:write(string.format('    [%q] = %q,\n', k, v))
        elseif type(v) == "boolean" then
            f:write(string.format('    [%q] = %s,\n', k, tostring(v)))
        elseif type(v) == "number" then
            f:write(string.format('    [%q] = %s,\n', k, tostring(v)))
        end
    end
    f:write("}\n")
    f:close()
    return true
end

local function mkdir_p(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parts = {}
    for part in path:gmatch("[^/]+") do table.insert(parts, part) end
    local current = path:sub(1,1) == "/" and "/" or ""
    for _, part in ipairs(parts) do
        current = current .. part .. "/"
        if lfs.attributes(current, "mode") ~= "directory" then
            lfs.mkdir(current)
        end
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function getKOReaderBaseDir()
    if os.getenv("KO_HOME") then
        return os.getenv("KO_HOME")
    end
    local isAndroid, android = pcall(require, "android")
    if isAndroid then
        return android.getExternalStoragePath() .. "/koreader"
    end
    if os.getenv("UBUNTU_APPLICATION_ISOLATION") then
        local app_id = os.getenv("APP_ID")
        local package_name = app_id:match("^(.-)_")
        return string.format("%s/%s", os.getenv("XDG_DATA_HOME"), package_name)
    end
    if os.getenv("APPIMAGE") or os.getenv("FLATPAK") or os.getenv("KO_MULTIUSER") then
        if os.getenv("XDG_CONFIG_HOME") then
            local xdg = os.getenv("XDG_CONFIG_HOME")
            if lfs.attributes(xdg, "mode") ~= "directory" then
                lfs.mkdir(xdg)
            end
            return string.format("%s/%s", xdg, "koreader")
        end
        local user_rw = string.format("%s/%s", os.getenv("HOME"), jit.os == "OSX" and "Library/Application Support" or ".config")
        if lfs.attributes(user_rw, "mode") ~= "directory" then
            lfs.mkdir(user_rw)
        end
        return string.format("%s/%s", user_rw, "koreader")
    end
    return "."
end

local base_dir = getKOReaderBaseDir()
if base_dir == "." then
    local cwd = lfs.currentdir()
    if cwd and cwd ~= "" then
        base_dir = cwd
    end
end
if base_dir ~= "." and lfs.attributes(base_dir, "mode") ~= "directory" then
    mkdir_p(base_dir)
end

local users_file = base_dir .. "/users.lua"
local users_data = loadLuaTable(users_file)

if not users_data then
    users_data = { current = "default" }
    saveLuaTable(users_file, users_data)
end

local current_user = users_data.current or "default"

MULTIUSER_CURRENT    = current_user
MULTIUSER_BASE_DIR   = base_dir
MULTIUSER_USERS_FILE = users_file

if current_user == "default" then return end

local user_data_dir = base_dir .. "/users/" .. current_user
mkdir_p(user_data_dir)
mkdir_p(user_data_dir .. "/plugins")
mkdir_p(user_data_dir .. "/patches")

local function patchDataStorage(DS)
    DS.getDataDir = function(self) return user_data_dir end
end

if package.loaded["datastorage"] then
    patchDataStorage(package.loaded["datastorage"])
else
    local orig_loader = package.preload["datastorage"]
    package.preload["datastorage"] = function()
        package.preload["datastorage"] = orig_loader
        local DS = require("datastorage")
        patchDataStorage(DS)
        package.loaded["datastorage"] = DS
        package.preload["datastorage"] = function() return DS end
        return DS
    end
end

local userpatch = package.loaded["userpatch"]
if userpatch then
    local orig_applyPatches = userpatch.applyPatches
    local user_patch_dir = user_data_dir .. "/patches"
    local ok_sort, sort = pcall(require, "sort")
    local natsort = ok_sort and sort.natsort_cmp() or nil

    local function runUserPatches(dir, priority)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        local patches = {}
        for entry in lfs.dir(dir) do
            if lfs.attributes(dir.."/"..entry, "mode") == "file"
               and entry:match("^"..priority.."%d*%-") then
                table.insert(patches, entry)
            end
        end
        if #patches == 0 then return end
        table.sort(patches, natsort)
        for _, entry in ipairs(patches) do
            local fullpath = dir .. "/" .. entry
            if fullpath:match("%.lua$") then
                local ok, err = pcall(dofile, fullpath)
                if not ok then
                    require("logger").warn("MultiUser: patch failed:", err)
                end
            end
        end
    end

    userpatch.applyPatches = function(priority)
        if priority < userpatch.late then
            orig_applyPatches(priority)
        end
        runUserPatches(user_patch_dir, priority)
    end
end

local function mergeSharedPluginsIntoDiscovered(discovered)
    local ok_util, util = pcall(require, "util")
    if not ok_util or not util then
        return discovered
    end
    local shared_root = base_dir .. "/plugins"
    if lfs.attributes(shared_root, "mode") ~= "directory" then
        return discovered
    end
    local seen = {}
    for _, e in ipairs(discovered) do
        if e.name then
            seen[e.name] = true
        end
    end
    local G = rawget(_G, "G_reader_settings")
    local plugins_disabled = G and G:readSetting("plugins_disabled")
    if type(plugins_disabled) ~= "table" then
        plugins_disabled = {}
    end
    for entry in lfs.dir(shared_root) do
        local plugin_root = shared_root .. "/" .. entry
        if lfs.attributes(plugin_root, "mode") == "directory" and entry:sub(-9) == ".koplugin" then
            local _, name = util.splitFilePathName(plugin_root)
            if not seen[name] then
                local mainfile = plugin_root .. "/main.lua"
                local metafile = plugin_root .. "/_meta.lua"
                local disabled = false
                if plugins_disabled[entry:sub(1, -10)] then
                    mainfile = metafile
                    disabled = true
                end
                table.insert(discovered, {
                    main = mainfile,
                    meta = metafile,
                    path = plugin_root,
                    disabled = disabled,
                    name = name,
                })
                seen[name] = true
            end
        end
    end
    return discovered
end

local function attachPluginLoaderMerge(mod)
    if mod.__koreader_multiuser_pl_hook then
        return
    end
    mod.__koreader_multiuser_pl_hook = true
    local orig = mod._discover
    function mod:_discover()
        local discovered
        local ok_disc, disc = pcall(orig, self)
        if ok_disc and type(disc) == "table" then
            discovered = disc
        else
            discovered = {}
        end
        local ok_m, merged = pcall(mergeSharedPluginsIntoDiscovered, discovered)
        if ok_m and type(merged) == "table" then
            return merged
        end
        return discovered
    end
end

local function resolvePluginLoaderFilePath()
    if package.searchpath then
        local p = package.searchpath("pluginloader", package.path)
        if p and lfs.attributes(p, "mode") == "file" then
            return p
        end
    end
    for template in package.path:gmatch("[^;]+") do
        local fpath = string.gsub(template, "%?", "pluginloader")
        if lfs.attributes(fpath, "mode") == "file" then
            return fpath
        end
    end
    return nil
end

local function loadPluginLoaderModuleNoRequire()
    local path = resolvePluginLoaderFilePath()
    if not path then
        return nil
    end
    local chunk, err = loadfile(path)
    if not chunk then
        return nil
    end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then
        return nil
    end
    return mod
end

local function hookPluginLoaderSharedPlugins()
    local PL = package.loaded["pluginloader"]
    if PL and PL._discover then
        attachPluginLoaderMerge(PL)
        return
    end

    local chained_preload = package.preload["pluginloader"]
    package.preload["pluginloader"] = function(name)
        local mod
        if type(chained_preload) == "function" then
            mod = chained_preload(name)
        else
            mod = loadPluginLoaderModuleNoRequire()
            if not mod then
                package.preload["pluginloader"] = nil
                mod = require(name)
            end
        end
        if type(mod) ~= "table" then
            return mod
        end
        package.loaded["pluginloader"] = mod
        attachPluginLoaderMerge(mod)
        package.preload["pluginloader"] = function()
            return mod
        end
        return mod
    end
end

hookPluginLoaderSharedPlugins()