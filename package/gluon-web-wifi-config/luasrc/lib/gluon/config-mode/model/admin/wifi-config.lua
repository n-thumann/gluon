local iwinfo = require 'iwinfo'
local uci = require("simple-uci").cursor()
local site = require 'gluon.site'
local wireless = require 'gluon.wireless'


local function txpower_list(phy)
	local list = iwinfo.nl80211.txpwrlist(phy) or { }
	local off  = tonumber(iwinfo.nl80211.txpower_offset(phy)) or 0
	local new  = { }
	local prev = -1
	for _, val in ipairs(list) do
		local dbm = val.dbm + off
		local mw  = math.floor(10 ^ (dbm / 10))
		if mw ~= prev then
			prev = mw
			table.insert(new, {
				display_dbm = dbm,
				display_mw  = mw,
				driver_dbm  = val.dbm,
			})
		end
	end
	return new
end

local f = Form(translate("WLAN"))

f:section(Section, nil, translate(
	"You can enable or disable your node's client and mesh network "
	.. "SSIDs here. Please don't disable the mesh network without "
	.. "a good reason, so other nodes can mesh with yours.<br /><br />"
	.. "It is also possible to configure the WLAN adapters transmission power "
	.. "here. Please note that the transmission power values include the antenna gain "
	.. "where available, but there are many devices for which the gain is unavailable or inaccurate."
))


local mesh_vifs_5ghz = {}


uci:foreach('wireless', 'wifi-device', function(config)
	local radio = config['.name']

	local is_5ghz = false
	local title
	if config.band == '2g' then
		title = translate("2.4GHz WLAN")
	elseif config.band == '5g' then
		is_5ghz = true
		title = translate("5GHz WLAN")
	else
		return
	end

	local p = f:section(Section, title)

	local function filter_existing_interfaces(interfaces)
		local out = {}
		for _, interface in ipairs(interfaces) do
			if uci:get('wireless', interface .. '_' .. radio) then
				table.insert(out, interface)
			end
		end
		return out
	end

	local function has_active_interfaces(interfaces)
		for _, interface in ipairs(interfaces) do
			if not uci:get_bool('wireless', interface .. '_' .. radio, 'disabled') then
				return true
			end
		end
		return false
	end

	local function vif_option(name, interfaces, msg)
		local existing_interfaces = filter_existing_interfaces(interfaces)

		if #existing_interfaces == 0 then
			return
		end

		local o = p:option(Flag, radio .. '_' .. name .. '_enabled', msg)
		o.default = has_active_interfaces(existing_interfaces)

		function o:write(data)
			for _, interface in ipairs(existing_interfaces) do
				uci:set('wireless', interface .. '_' .. radio, 'disabled', not data)
			end
		end

		return o
	end

	vif_option('client', {'client', 'owe'}, translate('Enable client network (access point)'))

	local mesh_vif = vif_option('mesh', {'mesh'}, translate("Enable mesh network (802.11s)"))
	if is_5ghz then
		table.insert(mesh_vifs_5ghz, mesh_vif)
	end

	local phy = wireless.find_phy(config)
	if not phy then
		return
	end

	local txpowers = txpower_list(phy)
	if #txpowers <= 1 then
		return
	end

	local tp = p:option(ListValue, radio .. '_txpower', translate("Transmission power"))
	tp.default = uci:get('wireless', radio, 'txpower') or 'default'

	tp:value('default', translate("(default)"))

	table.sort(txpowers, function(a, b) return a.driver_dbm > b.driver_dbm end)

	for _, entry in ipairs(txpowers) do
		tp:value(entry.driver_dbm, string.format("%i dBm (%i mW)", entry.display_dbm, entry.display_mw))
	end

	function tp:write(data)
		if data == 'default' then
			data = nil
		end
		uci:set('wireless', radio, 'txpower', data)
	end
end)


if wireless.device_uses_11a(uci) and not wireless.preserve_channels(uci) then
	local r = f:section(Section, translate("Outdoor Installation"), translate(
		"Configuring the node for outdoor use tunes the 5 GHz radio to a frequency "
		.. "and transmission power that conforms with the local regulatory requirements. "
		.. "It also enables dynamic frequency selection (DFS; radar detection). At the "
		.. "same time, mesh functionality is disabled as it requires neighbouring nodes "
		.. "to stay on the same channel permanently."
	))

	local outdoor = r:option(Flag, 'outdoor', translate("Node will be installed outdoors"))
	outdoor.default = uci:get_bool('gluon', 'wireless', 'outdoor')

	for _, mesh_vif in ipairs(mesh_vifs_5ghz) do
		mesh_vif:depends(outdoor, false)
		if outdoor.default then
			mesh_vif.default = not site.wifi5.mesh.disabled(false)
		end
	end

	function outdoor:write(data)
		uci:set('gluon', 'wireless', 'outdoor', data)
	end

	uci:foreach('wireless', 'wifi-device', function(config)
		local radio = config['.name']
		local band = uci:get('wireless', radio, 'band')

		if band ~= '5g' then
			return
		end

		local phy = wireless.find_phy(uci:get_all('wireless', radio))

		local ht = r:option(ListValue, 'outdoor_htmode', translate('HT Mode') .. ' (' .. radio .. ')')
		ht:depends(outdoor, true)
		ht.default = uci:get('gluon', 'wireless', 'outdoor_' .. radio .. '_htmode') or 'default'

		ht:value('default', translate("(default)"))
		for mode, available in pairs(iwinfo.nl80211.htmodelist(phy)) do
			if available then
				ht:value(mode, mode)
			end
		end

		function ht:write(data)
			if data == 'default' then
				data = nil
			end
			uci:set('gluon', 'wireless', 'outdoor_' .. radio .. '_htmode', data)
		end
	end)
end


function f:write()
	uci:commit('gluon')
	os.execute('/lib/gluon/upgrade/200-wireless')
	uci:commit('network')
	uci:commit('wireless')
end

return f
