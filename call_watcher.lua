-- charly-popup-appel — call_watcher.lua
-- Popup d'appel entrant avec lookup Jarvi. Ouvre Chrome au clic.
--
-- À placer dans ~/.hammerspoon/call_watcher.lua, puis ajouter dans
-- ~/.hammerspoon/init.lua : popupAppel = require("call_watcher")

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local LOOKUP_URL    = "https://charly-popup-appel.onrender.com/lookup"
local LOOKUP_TOKEN  = "6c0bd521489f79c439560a8b144eac14358eec1d5ff5b117fe8c2c80d6932f46"

local POPUP_WIDTH       = 380
local POPUP_HEIGHT      = 280
local POPUP_AUTOCLOSE_S = 15

local ALLOWED_HOSTS = {
    ["beta.jarvi.tech"] = true,
    ["app.jarvi.tech"]  = true,
    ["beta.jarvi.app"]  = true,  -- legacy, au cas où
    ["app.jarvi.app"]   = true,  -- legacy
}

local CALLDB_PATH = os.getenv("HOME")
    .. "/Library/Application Support/CallHistoryDB/CallHistory.storedata"
local CALLDB_DIR = os.getenv("HOME")
    .. "/Library/Application Support/CallHistoryDB"

------------------------------------------------------------
-- ÉTAT
------------------------------------------------------------
local lastSeenZdate = 0
local activePopup   = nil
local popupTimer    = nil
local pathWatcher   = nil
local pollTimer     = nil

local function log(...) print("[popup-appel]", ...) end

------------------------------------------------------------
-- Cache hammerspoon dock icon (pas de marteau dans le dock)
------------------------------------------------------------
if hs.dockIcon then
    hs.dockIcon(false)
end

------------------------------------------------------------
-- SQLite : dernier appel entrant
------------------------------------------------------------
local function getCurrentMaxZdate()
    local cmd = string.format(
        [[sqlite3 "%s" "SELECT COALESCE(MAX(ZDATE), 0) FROM ZCALLRECORD;"]],
        CALLDB_PATH
    )
    local h = io.popen(cmd); if not h then return 0 end
    local r = h:read("*a"); h:close()
    return tonumber(r) or 0
end

local function getLatestIncomingCall()
    local cmd = string.format(
        [[sqlite3 "%s" "SELECT ZADDRESS, ZDATE, ZANSWERED FROM ZCALLRECORD ]] ..
        [[WHERE ZORIGINATED = 0 AND ZDATE > %f ORDER BY ZDATE DESC LIMIT 1;"]],
        CALLDB_PATH, lastSeenZdate
    )
    local h = io.popen(cmd); if not h then return nil end
    local line = h:read("*l"); h:close()
    if not line or line == "" then return nil end
    local addr, zdate, ans = line:match("^([^|]*)|([^|]*)|([^|]*)$")
    if not addr or addr == "" then return nil end
    return { address = addr, zdate = tonumber(zdate) or 0, answered = tonumber(ans) == 1 }
end

------------------------------------------------------------
-- HTTP lookup
------------------------------------------------------------
local function lookupContact(phone, callback)
    local url = LOOKUP_URL .. "?phone=" .. hs.http.encodeForQuery(phone)
    local headers = { Authorization = "Bearer " .. LOOKUP_TOKEN }
    log("HTTP GET", phone)
    hs.http.asyncGet(url, headers, function(status, body, _)
        if status ~= 200 then
            log("lookup HTTP error", status)
            callback({ error = true, status = status })
            return
        end
        local ok, data = pcall(hs.json.decode, body)
        if not ok or not data then
            log("JSON decode failed")
            callback({ error = true })
            return
        end
        callback(data)
    end)
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function htmlEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
    s = s:gsub('"',"&quot;"):gsub("'","&#39;")
    return s
end

local function openInChrome(url)
    if not url or url == "" then return end
    local host = url:match("^https?://([^/]+)/")
    if not host or not ALLOWED_HOSTS[host] then
        log("blocked URL (host not in allowlist):", host); return
    end
    local safe = url:gsub("'", "'\\''")
    log("open in Chrome:", url)
    hs.execute("open -a 'Google Chrome' '" .. safe .. "'")
end

local function closePopup()
    if activePopup then activePopup:delete(); activePopup = nil end
    if popupTimer then popupTimer:stop(); popupTimer = nil end
end

-- Format un numéro FR pour affichage : +33676561341 -> +33 6 76 56 13 41
local function formatPhone(phone)
    if not phone then return "" end
    local p = phone:gsub("%s+", "")
    -- +33XXXXXXXXX (11 chars total après +33)
    local cc, rest = p:match("^(%+33)(%d+)$")
    if cc and rest and #rest == 9 then
        return cc .. " " .. rest:sub(1,1) .. " " .. rest:sub(2,3) .. " "
            .. rest:sub(4,5) .. " " .. rest:sub(6,7) .. " " .. rest:sub(8,9)
    end
    -- 0XXXXXXXXX (10 chiffres)
    if p:match("^0%d%d%d%d%d%d%d%d%d$") then
        return p:sub(1,2) .. " " .. p:sub(3,4) .. " " .. p:sub(5,6) .. " "
            .. p:sub(7,8) .. " " .. p:sub(9,10)
    end
    return phone
end

------------------------------------------------------------
-- HTML : design "carte claire" (cf. maquettes)
------------------------------------------------------------

local CSS = [[
  html, body {
    margin: 0; padding: 0;
    overflow: hidden !important;
    width: 100%; height: 100%;
  }
  ::-webkit-scrollbar { width: 0 !important; height: 0 !important; display: none !important; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: transparent;
    -webkit-font-smoothing: antialiased;
    display: flex;
    align-items: flex-end;
    justify-content: flex-end;
  }
  .card {
    margin: 6px;
    padding: 14px 16px 12px 16px;
    background: rgba(255,255,255,0.98);
    border-radius: 14px;
    box-shadow: 0 8px 28px rgba(0,0,0,0.18), 0 1px 3px rgba(0,0,0,0.08);
    color: #1c1c1e;
    width: calc(100% - 12px);
    box-sizing: border-box;
    transform-origin: bottom right;
    animation: slideIn 0.32s cubic-bezier(0.18, 0.89, 0.32, 1.05) both;
  }
  .card.no-anim { animation: none; }
  /* Anim qui ne déborde JAMAIS du viewport : monte légèrement + fade + scale. */
  @keyframes slideIn {
    0%   { transform: translateY(16px) scale(0.96); opacity: 0; }
    100% { transform: translateY(0)    scale(1);    opacity: 1; }
  }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    font-size: 10px; font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.6px; color: #8e8e93; margin-bottom: 10px;
  }
  .header .left { color: #5e9bf6; display: flex; align-items: center; gap: 4px; }
  .header .right { color: #8e8e93; }
  .row {
    display: flex; align-items: flex-start; gap: 12px;
  }
  .avatar {
    width: 44px; height: 44px; border-radius: 50%;
    border: 2px solid #cfddf6; background: #eaf1fe;
    color: #4781d8;
    display: flex; align-items: center; justify-content: center;
    font-size: 14px; font-weight: 700; flex-shrink: 0;
  }
  .avatar.client { border-color: #ddc8f6; background: #f3eaff; color: #8d4dd6; }
  .avatar.both { border-color: #c8b8f6; background: linear-gradient(135deg, #eaf1fe, #f3eaff); color: #6b5dd0; }
  .avatar.unknown { border-color: #d6d6da; background: #f0f0f2; color: #98989e; }
  .body { flex: 1; min-width: 0; }
  .name-line {
    display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
    margin-bottom: 1px;
  }
  .name { font-size: 16px; font-weight: 600; color: #1c1c1e; }
  .tag {
    font-size: 9px; font-weight: 700; letter-spacing: 0.5px;
    padding: 2px 6px; border-radius: 4px;
  }
  .tag.candidat { color: #3478f6; background: #e7f0fe; }
  .tag.client   { color: #9c4ef5; background: #f2e9fe; }
  .subtitle { font-size: 12px; color: #6e6e72; }
  .phone-line {
    font-size: 12px; color: #6e6e72; margin-top: 4px;
  }
  .project {
    display: flex; align-items: center; justify-content: space-between;
    margin-top: 11px; padding: 9px 11px;
    background: #f5f6fa; border-radius: 8px;
    text-decoration: none; color: #1c1c1e; cursor: pointer;
  }
  .project:hover { background: #ebeef5; }
  .project .left {
    display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1;
  }
  .project .icon { color: #5e9bf6; font-size: 13px; flex-shrink: 0; }
  .project .pname {
    font-size: 12px; font-weight: 500;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .project .status-pill {
    font-size: 10px; font-weight: 600;
    padding: 2px 7px; border-radius: 10px; flex-shrink: 0;
    white-space: nowrap;
  }
  .status-default { background: #fff3d9; color: #b8742a; }
  .status-progress { background: #e0ecff; color: #2a66c8; }
  .status-positive { background: #d8f0e0; color: #1d7a3a; }
  .status-negative { background: #fbdfdf; color: #b8302d; }
  .status-neutral  { background: #ececef; color: #6e6e72; }
  .more-projects {
    font-size: 11px; color: #5e9bf6; margin-top: 6px; padding-left: 4px;
    text-decoration: none; display: inline-block; cursor: pointer;
  }
  .more-projects:hover { text-decoration: underline; }
  .footer {
    display: flex; gap: 6px; align-items: center; margin-top: 12px;
  }
  .btn-primary {
    flex: 1;
    padding: 8px 10px;
    background: #f5f6fa; border-radius: 8px;
    text-align: center; font-size: 12px; font-weight: 500;
    color: #3478f6; text-decoration: none; cursor: pointer;
  }
  .btn-primary.client { color: #9c4ef5; }
  .btn-primary:hover { background: #ebeef5; }
  .btn-icon {
    width: 30px; height: 30px;
    background: #f5f6fa; border-radius: 8px;
    display: flex; align-items: center; justify-content: center;
    text-decoration: none; color: #6e6e72; cursor: pointer;
    font-size: 13px;
  }
  .btn-icon:hover { background: #ebeef5; }
  .skeleton-line {
    height: 8px; background: #ececef; border-radius: 4px; margin: 5px 0;
    animation: pulse 1.4s infinite ease-in-out;
  }
  @keyframes pulse {
    0%   { opacity: 0.6; }
    50%  { opacity: 1.0; }
    100% { opacity: 0.6; }
  }
  .skeleton-name { width: 65%; height: 11px; }
  .skeleton-sub  { width: 45%; }
  .error-banner {
    display: flex; align-items: center; gap: 6px;
    color: #b8302d; font-size: 11px; font-weight: 700;
    text-transform: uppercase; letter-spacing: 0.5px;
    margin-bottom: 6px;
  }
  .error-msg { font-size: 13px; color: #1c1c1e; margin-bottom: 4px; font-weight: 500; }
  .error-phone { font-size: 12px; color: #6e6e72; }
  /* === Multi-fiches (popup quand plusieurs profils Jarvi pour le même n°) === */
  .multi-card {
    display: flex; align-items: center; gap: 10px;
    padding: 10px 11px; margin: 7px 0 0 0;
    background: #f5f6fa; border-radius: 10px;
    text-decoration: none; color: inherit;
    cursor: pointer;
    transition: background 0.15s;
  }
  .multi-card:hover { background: #ebeef5; }
  .multi-card .avatar { width: 36px; height: 36px; font-size: 12px; border-width: 2px; }
  .multi-body { flex: 1; min-width: 0; overflow: hidden; }
  .multi-name-line {
    display: flex; align-items: center; gap: 5px; flex-wrap: wrap;
    margin-bottom: 2px;
  }
  .multi-name {
    font-size: 13px; font-weight: 600; color: #1c1c1e;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    max-width: 200px;
  }
  .multi-name-line .tag { font-size: 8px; padding: 1px 5px; }
  .multi-subtitle {
    font-size: 11px; color: #6e6e72;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .multi-arrow { color: #5e9bf6; font-size: 14px; flex-shrink: 0; }
  .multi-card:hover .multi-arrow { color: #82c7ff; }
]]

-- Catégorise un statut FR pour choisir une couleur de pill
local function statusClass(status_fr)
    if not status_fr then return "status-default" end
    local s = string.lower(status_fr)
    if s:find("recrut") or s:find("gagn") or s:find("hired") or s:find("won") then
        return "status-positive"
    end
    if s:find("refus") or s:find("perdu") or s:find("lost") or s:find("rejected") or s:find("not") then
        return "status-negative"
    end
    if s:find("cours") or s:find("contact") or s:find("entretien") or s:find("pipe")
       or s:find("interview") or s:find("scheduled") then
        return "status-progress"
    end
    return "status-default"
end

-- HTML pour avatar (initiales colorisées selon type)
local function avatarHtml(initials, kind)
    local cls = "avatar"
    if kind == "client" then cls = cls .. " client"
    elseif kind == "both" then cls = cls .. " both"
    elseif kind == "unknown" then cls = cls .. " unknown"
    end
    if not initials or initials == "" then
        initials = "?"
    end
    return string.format("<div class='%s'>%s</div>", cls, htmlEscape(initials))
end

local function tagsHtml(tags)
    if not tags or #tags == 0 then return "" end
    local parts = {}
    for _, t in ipairs(tags) do
        local cls = "candidat"
        if t == "CLIENT" then cls = "client" end
        table.insert(parts,
            "<span class='tag " .. cls .. "'>" .. htmlEscape(t) .. "</span>")
    end
    return table.concat(parts, " ")
end

-- HTML d'un projet (ligne cliquable)
local function projectHtml(p)
    local pill_class = statusClass(p.status)
    local status_html = ""
    if p.status and p.status ~= "" then
        status_html = string.format(
            "<span class='status-pill %s'>%s</span>",
            pill_class, htmlEscape(p.status)
        )
    end
    return string.format([[
<a class="project" href="%s">
  <span class="left">
    <span class="icon">📁</span>
    <span class="pname">%s</span>
  </span>
  %s
</a>]],
        htmlEscape(p.url),
        htmlEscape(p.name or "(sans nom)"),
        status_html
    )
end

-- HTML d'une card profil compacte (utilisée dans popup multi-fiches)
local function multiCardHtml(m)
    local kind = "candidat"
    if m.is_contact and m.is_talent then kind = "both"
    elseif m.is_contact and not m.is_talent then kind = "client" end
    local subtitle = m.compact_subtitle or ""
    return string.format([[
<a class="multi-card" href="%s">
  %s
  <div class="multi-body">
    <div class="multi-name-line">
      <span class="multi-name">%s</span>
      %s
    </div>
    <div class="multi-subtitle">%s</div>
  </div>
  <span class="multi-arrow">→</span>
</a>]],
        htmlEscape(m.primary_url or "#"),
        avatarHtml(m.initials or "?", kind),
        htmlEscape(m.name or "Sans nom"),
        tagsHtml(m.tags or {}),
        htmlEscape(subtitle)
    )
end

-- Construit la carte
local function buildHtml(phone, info, noAnim)
    local time_str = os.date("%H:%M")
    local pretty_phone = formatPhone(phone)
    local cls = noAnim and " no-anim" or ""

    -- MULTI-FICHES : si plusieurs profils Jarvi matchent le même numéro
    if info and info.found and (info.match_count or 1) > 1 then
        local count = info.match_count
        local cards = {}
        for _, m in ipairs(info.matches or {}) do
            table.insert(cards, multiCardHtml(m))
        end
        local body_html = string.format([[
<div class="card%s">
  <div class="header">
    <span class="left">📞 APPEL ENTRANT · %d fiches</span>
    <span class="right">%s</span>
  </div>
  <div class="phone-line" style="margin-bottom:2px;">%s</div>
  %s
  <div class="footer">
    <a class="btn-icon" href="copy://%s" style="margin-left:auto;">⧉</a>
    <a class="btn-icon" href="close://">✕</a>
  </div>
</div>]],
            cls, count, time_str,
            htmlEscape(pretty_phone),
            table.concat(cards),
            htmlEscape(phone)
        )
        return "<!doctype html><html><head><meta charset='utf-8'><style>"
            .. CSS .. "</style></head><body>" .. body_html .. "</body></html>"
    end

    -- LOADING
    if info == nil then
        local body_html = string.format([[
<div class="card%s">
  <div class="header">
    <span class="left">📞 RECHERCHE…</span>
    <span class="right">%s</span>
  </div>
  <div class="row">
    %s
    <div class="body">
      <div class="skeleton-line skeleton-name"></div>
      <div class="skeleton-line skeleton-sub"></div>
      <div class="skeleton-line" style="width:80%%;margin-top:10px;"></div>
      <div class="phone-line" style="margin-top:8px;">%s</div>
    </div>
  </div>
</div>]],
            cls,
            time_str,
            avatarHtml("…", "unknown"),
            htmlEscape(pretty_phone)
        )
        return "<!doctype html><html><head><meta charset='utf-8'><style>"
            .. CSS .. "</style></head><body>" .. body_html .. "</body></html>"
    end

    -- ERREUR
    if info.error then
        local body_html = string.format([[
<div class="card%s">
  <div class="error-banner">⚠ ERREUR DE LOOKUP</div>
  <div class="error-msg">Lookup serveur injoignable</div>
  <div class="error-phone">%s</div>
  <div class="footer">
    <a class="btn-icon" href="close://" style="margin-left:auto;">✕</a>
  </div>
</div>]],
            cls,
            htmlEscape(pretty_phone)
        )
        return "<!doctype html><html><head><meta charset='utf-8'><style>"
            .. CSS .. "</style></head><body>" .. body_html .. "</body></html>"
    end

    -- INCONNU
    if not info.found then
        local body_html = string.format([[
<div class="card%s">
  <div class="header">
    <span class="left">📞 APPEL ENTRANT · INCONNU</span>
    <span class="right">%s</span>
  </div>
  <div class="row">
    %s
    <div class="body">
      <div class="name">%s</div>
      <div class="subtitle">Pas trouvé dans Jarvi</div>
    </div>
  </div>
  <div class="footer">
    <a class="btn-primary" href="https://beta.jarvi.tech/#/ats/profiles">+ Créer un profil →</a>
    <a class="btn-icon" href="copy://%s">⧉</a>
    <a class="btn-icon" href="close://">✕</a>
  </div>
</div>]],
            cls,
            time_str,
            avatarHtml("?", "unknown"),
            htmlEscape(pretty_phone),
            htmlEscape(phone)
        )
        return "<!doctype html><html><head><meta charset='utf-8'><style>"
            .. CSS .. "</style></head><body>" .. body_html .. "</body></html>"
    end

    -- TROUVÉ
    local kind = "candidat"
    if info.is_contact and info.is_talent then kind = "both"
    elseif info.is_contact and not info.is_talent then kind = "client" end

    local subtitle = ""
    if info.title and info.company then
        subtitle = info.title .. " · " .. info.company
    else
        subtitle = info.title or info.company or ""
    end

    -- 1er projet en grand + lien "+N autres" si plus
    local projects_html = ""
    if info.projects and #info.projects > 0 then
        projects_html = projectHtml(info.projects[1])
        local extras = (info.total_projects or #info.projects) - 1
        if extras > 0 then
            local lbl = (extras == 1) and "+ 1 autre projet"
                or ("+ " .. extras .. " autres projets")
            projects_html = projects_html .. string.format(
                "<a class='more-projects' href='%s'>%s →</a>",
                htmlEscape(info.primary_url or ""), htmlEscape(lbl)
            )
        end
    end

    local btn_class = (info.primary_kind == "client") and "btn-primary client"
        or "btn-primary"
    local btn_label = (info.primary_kind == "client") and "Ouvrir fiche client →"
        or "Ouvrir dans Jarvi →"

    local subtitle_html = ""
    if subtitle ~= "" then
        subtitle_html = "<div class='subtitle'>" .. htmlEscape(subtitle) .. "</div>"
    end

    local body_html = string.format([[
<div class="card%s">
  <div class="header">
    <span class="left">📞 APPEL ENTRANT</span>
    <span class="right">%s</span>
  </div>
  <div class="row">
    %s
    <div class="body">
      <div class="name-line">
        <span class="name">%s</span>
        %s
      </div>
      %s
      <div class="phone-line">%s</div>
    </div>
  </div>
  %s
  <div class="footer">
    <a class="%s" href="%s">%s</a>
    <a class="btn-icon" href="copy://%s">⧉</a>
    <a class="btn-icon" href="close://">✕</a>
  </div>
</div>]],
        cls,
        time_str,
        avatarHtml(info.initials or "?", kind),
        htmlEscape(info.name or "Sans nom"),
        tagsHtml(info.tags or {}),
        subtitle_html,
        htmlEscape(pretty_phone),
        projects_html,
        btn_class,
        htmlEscape(info.primary_url or "#"),
        btn_label,
        htmlEscape(phone)
    )

    return "<!doctype html><html><head><meta charset='utf-8'><style>"
        .. CSS .. "</style></head><body>" .. body_html .. "</body></html>"
end

------------------------------------------------------------
-- Rendu popup
------------------------------------------------------------
local function renderPopup(phone, info)
    local isUpdate = (activePopup ~= nil)
    local html = buildHtml(phone, info, isUpdate)

    -- (Re)set le timer auto-close à chaque render
    if popupTimer then popupTimer:stop() end
    popupTimer = hs.timer.doAfter(POPUP_AUTOCLOSE_S, closePopup)

    -- Hauteur dynamique : popup standard (280px) ou multi-fiches (130 + 65*N)
    local height = POPUP_HEIGHT
    if info and info.found and (info.match_count or 1) > 1 then
        height = 140 + 65 * info.match_count
    end

    if isUpdate then
        -- on garde la même fenêtre, on remplace juste son HTML (sans re-anim)
        -- mais on resize si la hauteur a changé (cas LOADING → multi)
        local f = activePopup:frame()
        if f and math.abs(f.h - height) > 5 then
            local screen = hs.screen.mainScreen():frame()
            activePopup:frame(hs.geometry.rect(
                screen.x + screen.w - POPUP_WIDTH - 14,
                screen.y + screen.h - height - 20,
                POPUP_WIDTH, height
            ))
        end
        activePopup:html(html)
        return
    end

    -- Création initiale (1er render) — position bas-droite
    local screen = hs.screen.mainScreen():frame()
    local rect = hs.geometry.rect(
        screen.x + screen.w - POPUP_WIDTH - 14,
        screen.y + screen.h - height - 20,
        POPUP_WIDTH, height
    )

    activePopup = hs.webview.new(rect)
        :windowStyle({"borderless", "nonactivating"})
        :level(hs.drawing.windowLevels.floating)
        :allowTextEntry(false)
        :allowGestures(false)
        :transparent(true)
        :shadow(false)            -- pas de drop-shadow native (on a celle CSS)
        :html(html)

    activePopup:policyCallback(function(action, _wv, navAction)
        if action == "navigationAction" and navAction and navAction.request then
            -- request.URL peut être une string OU un userdata selon WebKit
            local url = tostring(navAction.request.URL or "")
            if url == "" or url:match("^about:") or url:match("^data:") then
                return true
            end
            if url:match("^close://") then
                closePopup(); return false
            end
            local copy_val = url:match("^copy://(.+)$")
            if copy_val then
                copy_val = copy_val:gsub("%%(%x%x)", function(h)
                    return string.char(tonumber(h, 16))
                end)
                hs.pasteboard.setContents(copy_val)
                hs.alert.show("Numéro copié")
                return false
            end
            openInChrome(url)
            closePopup()
            return false
        end
        return true
    end)

    activePopup:show()
end

------------------------------------------------------------
-- Pipeline
------------------------------------------------------------
local function handleIncomingCall(call)
    log("Appel entrant détecté :", call.address)
    local got_response = false
    -- N'affiche le LOADING que si la réponse met >800ms (sinon on évite
    -- un flash inutile et on n'a qu'une seule animation slide).
    hs.timer.doAfter(0.8, function()
        if not got_response and activePopup == nil then
            renderPopup(call.address, nil)
        end
    end)
    lookupContact(call.address, function(info)
        got_response = true
        renderPopup(call.address, info)
    end)
end

------------------------------------------------------------
-- Watcher + polling de secours
------------------------------------------------------------
local function checkForNewCall(_source)
    local call = getLatestIncomingCall()
    if not call then return end
    if call.zdate <= lastSeenZdate then return end
    lastSeenZdate = call.zdate
    handleIncomingCall(call)
end

local function onFileChanged(_paths, _f)
    hs.timer.doAfter(0.2, function() checkForNewCall("watcher") end)
end

local function start()
    if not hs.fs.attributes(CALLDB_PATH) then
        hs.alert.show("popup-appel : CallHistory introuvable")
        log("DB introuvable :", CALLDB_PATH)
        return
    end
    lastSeenZdate = getCurrentMaxZdate()
    log("Init lastSeenZdate =", lastSeenZdate)
    pathWatcher = hs.pathwatcher.new(CALLDB_DIR, onFileChanged):start()
    log("Watcher démarré sur", CALLDB_DIR)
    -- Polling toutes les 1 seconde : macOS écrit dans CallHistory.storedata
    -- uniquement à la fin de l'appel (limitation système, pas contournable).
    -- 1s est le bon compromis entre réactivité et charge SQLite.
    pollTimer = hs.timer.doEvery(1, function()
        checkForNewCall("poll")
    end)
    log("Polling actif (1s)")
    hs.alert.show("popup-appel actif (test local)")
end

------------------------------------------------------------
-- Hotkey test
------------------------------------------------------------
hs.hotkey.bind({"alt", "cmd"}, "P", function()
    local testPhone = "+33676561341"
    log("Test manuel popup", testPhone)
    handleIncomingCall({ address = testPhone })
end)

start()

return {
    test = function(phone)
        renderPopup(phone, nil)
        lookupContact(phone, function(info) renderPopup(phone, info) end)
    end,
    stop = function()
        if pathWatcher then pathWatcher:stop() end
        if pollTimer then pollTimer:stop(); pollTimer = nil end
        closePopup()
    end,
}
