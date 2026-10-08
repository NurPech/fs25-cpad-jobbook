-- JobQueue
--
-- A job queue per vehicle for Courseplay (CP) and AutoDrive (AD). A job is a CP course plus an
-- AD destination (the field). When CP finishes a course and more jobs are open, the next job is
-- started instead of letting AD park the vehicle.
--
-- Starting a job:
--   1. load the CP course into the vehicle and forget the remembered waypoint (start at the beginning)
--   2. put the field into the AD destination slot of the current AD mode (the mode isn't changed)
--      and switch the CP helper on
--   3. start AD. When AD reaches the destination it hands over to CP on its own
--      (AutoDrive.passToExternalMod_CP), so arrival doesn't have to be detected here.
--
-- Finishing: AutoDrive.onCpFinished is wrapped. Open job -> start it (deferred by a short time so
-- CP can finish cleanly). No open job -> AD parks as usual.
--
-- The queues are saved with the savegame (<savegame>/cpAdJobBook.xml). Console commands only, no menu yet.

JobQueue = {}
JobQueue.modName = g_currentModName
JobQueue.queues = {}        -- [vehicle unique id] = { jobs = {...}, running = bool, current = job }
JobQueue.pending = {}       -- deferred job starts
JobQueue.START_DELAY = 500
JobQueue.MAX_START_TRIES = 20
JobQueue.MAX_LIST_LINES = 15
JobQueue.MAX_SCAN_DEPTH = 4

function JobQueue.log(fmt, ...)
    print(string.format("[JobQueue] " .. fmt, ...))
end

function JobQueue.warn(fmt, ...)
    Logging.warning("[JobQueue] " .. fmt, ...)
end

---Runs func and logs instead of raising, so a bug here can never break loading or saving a savegame.
function JobQueue.protected(name, func, ...)
    local ok, err = pcall(func, ...)
    if not ok then
        JobQueue.warn("Error in %s: %s", name, tostring(err))
    end
end

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

---The AutoDrive table of the AutoDrive mod, or nil if AutoDrive isn't installed.
function JobQueue.getAutoDrive()
    return FS25_AutoDrive ~= nil and FS25_AutoDrive.AutoDrive or nil
end

---The vehicle the local player currently sits in (root vehicle), or nil.
function JobQueue.getControlledVehicle()
    local vehicle = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
    if vehicle == nil then
        return nil
    end

    return vehicle:getRootVehicle()
end

function JobQueue.getVehicleKey(vehicle)
    return vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or tostring(vehicle.id)
end

function JobQueue.getVehicleName(vehicle)
    return vehicle.getName ~= nil and vehicle:getName() or "vehicle"
end

function JobQueue:getQueue(vehicle, create)
    local key = JobQueue.getVehicleKey(vehicle)
    local queue = self.queues[key]

    if queue == nil and create then
        queue = { jobs = {}, running = false, current = nil }
        self.queues[key] = queue
    end

    return queue
end

---A file-like object for appendLoadedCpCourse, which only calls file:load(). Same behavior as the
-- File class of Courseplay, but without depending on it.
local function makeCourseFile(course)
    return {
        name = course.name,
        fullPath = course.path .. "/" .. course.name,
        load = function(self, xmlSchema, xmlBaseKey, lambda, class, ...)
            local xmlFile = XMLFile.load("jobQueueCourseXml", self.fullPath, xmlSchema)
            if xmlFile == nil then
                return false
            end

            local result
            if class then
                result = lambda(class, xmlFile, xmlBaseKey, (...), self.name)
            else
                result = lambda(xmlFile, xmlBaseKey, (...), self.name)
            end

            xmlFile:delete()
            return result
        end
    }
end

---------------------------------------------------------------------------------------------------
-- Courses (files of the Courseplay course manager)
---------------------------------------------------------------------------------------------------

function JobQueue.getCourseRoot()
    -- same path as Courseplay: <modSettings>/FS25_Courseplay/Courses/<mapId>/Singleplayer
    return string.format("%smodSettings/FS25_Courseplay/Courses/%s/Singleplayer", getUserProfileAppPath(), g_currentMission.missionInfo.mapId)
end

local function scanDirectory(path, relative, result, depth)
    local entries = { dirs = {}, files = {} }

    function entries:onEntry(name, isDirectory)
        table.insert(isDirectory and self.dirs or self.files, name)
    end

    getFiles(path, "onEntry", entries)
    table.sort(entries.dirs)
    table.sort(entries.files)

    for _, name in ipairs(entries.files) do
        table.insert(result, { path = path, name = name, relative = relative .. name })
    end

    if depth < JobQueue.MAX_SCAN_DEPTH then
        for _, name in ipairs(entries.dirs) do
            scanDirectory(path .. "/" .. name, relative .. name .. "/", result, depth + 1)
        end
    end
end

function JobQueue.findCourses(filter)
    local all = {}
    scanDirectory(JobQueue.getCourseRoot(), "", all, 1)

    if filter == nil or filter == "" then
        return all
    end

    local needle = string.lower(filter)
    local result = {}
    for _, course in ipairs(all) do
        if string.find(string.lower(course.relative), needle, 1, true) ~= nil then
            table.insert(result, course)
        end
    end

    return result
end

---------------------------------------------------------------------------------------------------
-- AutoDrive destinations
---------------------------------------------------------------------------------------------------

---Sorted list of all AutoDrive destinations, optionally filtered by name.
function JobQueue.findDestinations(filter)
    local AD = JobQueue.getAutoDrive()
    if AD == nil then
        return {}
    end

    local needle = (filter ~= nil and filter ~= "") and string.lower(filter) or nil
    local result = {}

    for _, destination in pairs(AD:GetAvailableDestinations()) do
        if needle == nil or string.find(string.lower(destination.name), needle, 1, true) ~= nil then
            table.insert(result, destination)
        end
    end

    table.sort(result, function(a, b)
        return a.name < b.name
    end)

    return result
end

function JobQueue.getDestination(markerId)
    local AD = JobQueue.getAutoDrive()
    return AD ~= nil and AD:GetAvailableDestinations()[markerId] or nil
end

---The current marker id of the job's destination, or nil if it doesn't exist anymore. Marker ids can
-- change when the AutoDrive network is edited, so the saved name is used to find it again.
function JobQueue.resolveMarkerId(job)
    local AD = JobQueue.getAutoDrive()
    if AD == nil then
        return nil
    end

    local destinations = AD:GetAvailableDestinations()

    local byId = destinations[job.markerId]
    if byId ~= nil and (job.markerName == nil or byId.name == job.markerName) then
        return byId.id
    end

    if job.markerName ~= nil then
        for _, destination in pairs(destinations) do
            if destination.name == job.markerName then
                return destination.id
            end
        end
    end

    return nil
end

---------------------------------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------------------------------

---Why the vehicle can't take a new job right now, or nil if it can.
function JobQueue.getBusyReason(vehicle)
    if vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return "AutoDrive not available on this vehicle"
    end

    if vehicle.ad.stateModule:isActive() then
        return "AutoDrive is still active"
    end

    if vehicle.getIsCpActive ~= nil and vehicle:getIsCpActive() then
        return "Courseplay is still active"
    end

    return nil
end

---Loads the course, points AutoDrive at the field and starts it. Returns true on success.
function JobQueue:startJob(vehicle, job)
    local AD = JobQueue.getAutoDrive()
    if AD == nil then
        JobQueue.warn("AutoDrive not found")
        return false
    end

    if vehicle.appendLoadedCpCourse == nil then
        JobQueue.warn("%s has no Courseplay course support", JobQueue.getVehicleName(vehicle))
        return false
    end

    local markerId = JobQueue.resolveMarkerId(job)
    local destination = markerId ~= nil and JobQueue.getDestination(markerId) or nil
    if destination == nil then
        JobQueue.warn("AutoDrive destination '%s' doesn't exist anymore", tostring(job.markerName or job.markerId))
        return false
    end
    job.markerId = markerId
    job.markerName = destination.name

    -- appendLoadedCpCourse has no return value (Courseplay ignores it too), so check the result
    vehicle:appendLoadedCpCourse(makeCourseFile(job.course))
    if not vehicle:hasCpCourse() then
        JobQueue.warn("Could not load course '%s'", job.course.relative)
        return false
    end

    -- the previous course is finished, so start the new one at its beginning
    vehicle:rememberCpLastWaypointIx()

    -- The AutoDrive mode stays as the player set it. The field is the "target", which is the first
    -- marker (top row in the AutoDrive HUD) in the modes that can work with Courseplay:
    --   pickup (load): first = target (the field), second = pickup place (e.g. silo, stays),
    --     bottom row = fill type. The first marker has to be the current field, so AutoDrive
    --     returns to it after refilling, and it is the position AutoDrive hands over to Courseplay at.
    --   drive to / deliver to: the single destination is the first marker as well.
    local state = vehicle.ad.stateModule
    local mode = state:getMode()

    if mode ~= AD.MODE_LOAD and mode ~= AD.MODE_DRIVETO and mode ~= AD.MODE_DELIVERTO then
        JobQueue.warn("%s: AutoDrive mode %s isn't supported, use pickup (load), drive to or deliver to", JobQueue.getVehicleName(vehicle), tostring(mode))
        return false
    end

    state:setFirstMarker(markerId)

    local helperCp = FS25_AutoDrive.ADStateModule ~= nil and FS25_AutoDrive.ADStateModule.HELPER_CP or 1
    state:setUsedHelper(helperCp)
    state:setStartHelper(true)
    vehicle.ad.restartCP = false
    vehicle.ad.onRouteToPark = false

    JobQueue.log("%s: '%s' -> '%s' (AutoDrive mode %s, first marker '%s', second marker '%s')", JobQueue.getVehicleName(vehicle), job.course.relative, destination.name,
        tostring(mode), tostring(state:getFirstMarkerName()), tostring(state:getSecondMarkerName()))
    state:getCurrentMode():start()

    return true
end

---Called when Courseplay finished a course. Returns true if the next job takes over, so AutoDrive
-- must not park the vehicle.
function JobQueue:handleCpFinished(vehicle)
    local queue = self:getQueue(vehicle, false)
    if queue == nil or not queue.running then
        return false
    end

    local nextJob = table.remove(queue.jobs, 1)
    if nextJob == nil then
        JobQueue.log("%s: no open jobs left, AutoDrive parks", JobQueue.getVehicleName(vehicle))
        queue.running = false
        queue.current = nil
        return false
    end

    queue.current = nextJob
    table.insert(self.pending, { vehicle = vehicle, job = nextJob, delay = JobQueue.START_DELAY, tries = 0 })

    return true
end

function JobQueue:update(dt)
    for i = #self.pending, 1, -1 do
        local entry = self.pending[i]
        entry.delay = entry.delay - dt

        if entry.delay <= 0 then
            table.remove(self.pending, i)

            local vehicle = entry.vehicle
            local queue = vehicle ~= nil and not vehicle.isDeleted and self:getQueue(vehicle, false) or nil

            if queue ~= nil and queue.running then
                local busy = JobQueue.getBusyReason(vehicle)

                if busy ~= nil and entry.tries < JobQueue.MAX_START_TRIES then
                    -- Courseplay may still be stopping, try again shortly
                    entry.tries = entry.tries + 1
                    entry.delay = JobQueue.START_DELAY
                    table.insert(self.pending, entry)
                elseif busy ~= nil or not self:startJob(vehicle, entry.job) then
                    JobQueue.warn("%s: stopped the queue (%s)", JobQueue.getVehicleName(vehicle), busy or "job could not be started")
                    queue.running = false
                    queue.current = nil
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Console commands (stage 1 has no menu)
---------------------------------------------------------------------------------------------------

local function printLimited(lines)
    for i = 1, math.min(#lines, JobQueue.MAX_LIST_LINES) do
        print(lines[i])
    end

    if #lines > JobQueue.MAX_LIST_LINES then
        print(string.format("... and %d more, narrow the filter", #lines - JobQueue.MAX_LIST_LINES))
    end
end

---Splits console arguments at "|" into the course words and the destination words.
local function splitArgs(...)
    local courseWords, destinationWords = {}, {}
    local target = courseWords

    for _, arg in ipairs({ ... }) do
        if arg == "|" then
            target = destinationWords
        else
            table.insert(target, arg)
        end
    end

    return table.concat(courseWords, " "), table.concat(destinationWords, " ")
end

---True if every word of text is contained in haystack (case insensitive).
local function matchesWords(text, haystack)
    haystack = string.lower(haystack)

    for word in string.gmatch(string.lower(text), "%S+") do
        if string.find(haystack, word, 1, true) == nil then
            return false
        end
    end

    return true
end

---Finds exactly one entry whose name contains all words of text. Returns the entry, or nil and
-- a message. An exact name or a name that ends with the text wins over other matches, so
-- "Feld 02" isn't ambiguous with "Feld 020".
local function pickUnique(text, entries, getName, what)
    if text == nil or text == "" then
        return nil, string.format("no %s given", what)
    end

    local matches = {}
    for _, entry in ipairs(entries) do
        if matchesWords(text, getName(entry)) then
            table.insert(matches, entry)
        end
    end

    if #matches == 1 then
        return matches[1]
    end

    local lowerText = string.lower(text)
    for _, rule in ipairs({
        function(name) return name == lowerText end,
        function(name) return string.sub(name, -#lowerText) == lowerText end
    }) do
        local found, count = nil, 0
        for _, entry in ipairs(matches) do
            if rule(string.lower(getName(entry))) then
                found, count = entry, count + 1
            end
        end

        if count == 1 then
            return found
        end
    end

    if #matches == 0 then
        return nil, string.format("no %s matches '%s'", what, text)
    end

    local names = {}
    for i = 1, math.min(#matches, 8) do
        table.insert(names, getName(matches[i]))
    end

    return nil, string.format("%d %ss match '%s', be more precise: %s%s", #matches, what, text, table.concat(names, " | "), #matches > 8 and " | ..." or "")
end

function JobQueue:consoleCourses(...)
    local filter = table.concat({ ... }, " ")
    local words = {}
    for word in string.gmatch(filter, "%S+") do
        table.insert(words, word)
    end

    local courses = {}
    for _, course in ipairs(JobQueue.findCourses()) do
        if matchesWords(filter, course.relative) then
            table.insert(courses, course)
        end
    end

    if #words == 0 then
        -- without a filter only show how many courses each folder has
        local counts, order = {}, {}
        for _, course in ipairs(courses) do
            local folder = string.match(course.relative, "^([^/]+)/") or "(root)"
            if counts[folder] == nil then
                counts[folder] = 0
                table.insert(order, folder)
            end
            counts[folder] = counts[folder] + 1
        end

        local lines = {}
        for _, folder in ipairs(order) do
            table.insert(lines, string.format("%4d  %s", counts[folder], folder))
        end
        printLimited(lines)

        return string.format("%d course(s) in %d folder(s), filter with e.g. jqCourses kalken F02", #courses, #order)
    end

    local lines = {}
    for _, course in ipairs(courses) do
        table.insert(lines, course.relative)
    end
    printLimited(lines)

    return string.format("%d course(s) match", #courses)
end

function JobQueue:consoleDestinations(...)
    if JobQueue.getAutoDrive() == nil then
        return "AutoDrive not found"
    end

    local destinations = {}
    local filter = table.concat({ ... }, " ")
    for _, destination in ipairs(JobQueue.findDestinations()) do
        if matchesWords(filter, destination.name) then
            table.insert(destinations, destination)
        end
    end

    local lines = {}
    for _, destination in ipairs(destinations) do
        table.insert(lines, destination.name)
    end
    printLimited(lines)

    return string.format("%d destination(s)%s", #destinations, filter == "" and ", filter with e.g. jqDest Feld 02" or " match")
end

function JobQueue:consoleAdd(...)
    local usage = "usage: jqAdd <course words> | <destination words>, e.g. jqAdd kalken F02 12m | Feld 02"

    local vehicle = JobQueue.getControlledVehicle()
    if vehicle == nil then
        return "Sit in the vehicle first"
    end

    local courseText, destinationText = splitArgs(...)

    local course, message = pickUnique(courseText, JobQueue.findCourses(), function(entry) return entry.relative end, "course")
    if course == nil then
        return message .. " (" .. usage .. ")"
    end

    local destination
    destination, message = pickUnique(destinationText, JobQueue.findDestinations(), function(entry) return entry.name end, "destination")
    if destination == nil then
        return message .. " (" .. usage .. ")"
    end

    local queue = self:getQueue(vehicle, true)
    table.insert(queue.jobs, { course = course, markerId = destination.id, markerName = destination.name })

    return string.format("%s: job %d: '%s' -> '%s'", JobQueue.getVehicleName(vehicle), #queue.jobs, course.relative, destination.name)
end

function JobQueue:consoleList()
    local vehicle = JobQueue.getControlledVehicle()
    if vehicle == nil then
        return "Sit in the vehicle first"
    end

    local queue = self:getQueue(vehicle, false)
    if queue == nil or (#queue.jobs == 0 and queue.current == nil) then
        return "Queue is empty"
    end

    if queue.current ~= nil then
        print(string.format(" now  %s -> %s", queue.current.course.relative, queue.current.markerName or "?"))
    end

    for i, job in ipairs(queue.jobs) do
        print(string.format("%4d  %s -> %s", i, job.course.relative, job.markerName or "?"))
    end

    return string.format("%s: %d open job(s), queue %s", JobQueue.getVehicleName(vehicle), #queue.jobs, queue.running and "running" or "not started")
end

function JobQueue:consoleStart()
    local vehicle = JobQueue.getControlledVehicle()
    if vehicle == nil then
        return "Sit in the vehicle first"
    end

    local queue = self:getQueue(vehicle, false)
    if queue == nil or #queue.jobs == 0 then
        return "Queue is empty, add jobs with jqAdd"
    end

    local busy = JobQueue.getBusyReason(vehicle)
    if busy ~= nil then
        return "Can't start: " .. busy
    end

    local job = table.remove(queue.jobs, 1)
    queue.running = true
    queue.current = job

    if not self:startJob(vehicle, job) then
        queue.running = false
        queue.current = nil
        return "Could not start the first job, see the log"
    end

    return string.format("Started, %d job(s) open afterwards", #queue.jobs)
end

function JobQueue:consoleStop()
    local vehicle = JobQueue.getControlledVehicle()
    if vehicle == nil then
        return "Sit in the vehicle first"
    end

    local queue = self:getQueue(vehicle, false)
    if queue == nil then
        return "Queue is empty"
    end

    queue.running = false
    queue.current = nil
    queue.jobs = {}

    return "Queue cleared and stopped (the current drive or course is not interrupted)"
end

---------------------------------------------------------------------------------------------------
-- Savegame
---------------------------------------------------------------------------------------------------

JobQueue.FILENAME = "cpAdJobBook.xml"

function JobQueue.getSavegamePath()
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if missionInfo == nil or missionInfo.savegameDirectory == nil then
        return nil
    end

    return missionInfo.savegameDirectory .. "/" .. JobQueue.FILENAME
end

---Course entry as found by findCourses, rebuilt from the path relative to the course root.
local function courseFromRelative(relative)
    local directory, name = string.match(relative, "^(.*)/([^/]+)$")
    local path = JobQueue.getCourseRoot()

    if directory ~= nil then
        path = path .. "/" .. directory
    else
        name = relative
    end

    return { path = path, name = name, relative = relative }
end

local function saveJob(xmlFile, key, job)
    xmlFile:setString(key .. "#course", job.course.relative)
    xmlFile:setString(key .. "#markerName", job.markerName or "")
    xmlFile:setInt(key .. "#markerId", job.markerId or 0)
end

local function loadJob(xmlFile, key)
    local relative = xmlFile:getString(key .. "#course")
    if relative == nil then
        return nil
    end

    local markerName = xmlFile:getString(key .. "#markerName")
    if markerName == "" then
        markerName = nil
    end

    return { course = courseFromRelative(relative), markerId = xmlFile:getInt(key .. "#markerId", 0), markerName = markerName }
end

function JobQueue.saveToXMLFile()
    local path = JobQueue.getSavegamePath()
    if path == nil then
        return
    end

    local xmlFile = XMLFile.create("cpAdJobBookXml", path, "jobBook")
    if xmlFile == nil then
        return
    end

    local count = 0
    for vehicleKey, queue in pairs(JobQueue.queues) do
        if #queue.jobs > 0 or queue.running then
            local key = string.format("jobBook.vehicle(%d)", count)
            xmlFile:setString(key .. "#id", tostring(vehicleKey))
            xmlFile:setBool(key .. "#running", queue.running)

            if queue.current ~= nil then
                saveJob(xmlFile, key .. ".current", queue.current)
            end

            for i, job in ipairs(queue.jobs) do
                saveJob(xmlFile, string.format("%s.job(%d)", key, i - 1), job)
            end

            count = count + 1
        end
    end

    xmlFile:save()
    xmlFile:delete()

    JobQueue.log("saved the queues of %d vehicle(s)", count)
end

---Loads the saved queues. A queue that was running stays running: the vehicle's Courseplay course
-- is continued by hand (Courseplay remembers its waypoint), and when it finishes, the queue goes on
-- with the next open job. jqStop cancels that.
function JobQueue.loadFromXMLFile()
    local path = JobQueue.getSavegamePath()
    if path == nil then
        return
    end

    local xmlFile = XMLFile.loadIfExists("cpAdJobBookXml", path, nil)
    if xmlFile == nil then
        return
    end

    local count = 0
    for _, key in xmlFile:iterator("jobBook.vehicle") do
        local vehicleKey = xmlFile:getString(key .. "#id")

        if vehicleKey ~= nil then
            local queue = { jobs = {}, running = xmlFile:getBool(key .. "#running", false), current = nil }

            if xmlFile:hasProperty(key .. ".current") then
                queue.current = loadJob(xmlFile, key .. ".current")
            end

            for _, jobKey in xmlFile:iterator(key .. ".job") do
                local job = loadJob(xmlFile, jobKey)
                if job ~= nil then
                    table.insert(queue.jobs, job)
                end
            end

            JobQueue.queues[vehicleKey] = queue
            count = count + 1
        end
    end

    xmlFile:delete()

    JobQueue.log("loaded the queues of %d vehicle(s)", count)
end

---------------------------------------------------------------------------------------------------
-- Hooks and lifecycle
---------------------------------------------------------------------------------------------------

---Wraps AutoDrive.onCpFinished. The event is dispatched through the specialization table at call
-- time, so replacing the function there takes effect for all vehicles.
function JobQueue.installHooks()
    local AD = JobQueue.getAutoDrive()

    if AD == nil then
        JobQueue.log("AutoDrive not found, nothing to do")
        return false
    end

    if AD.onCpFinished == nil then
        JobQueue.warn("AutoDrive.onCpFinished not found, this AutoDrive version is not supported")
        return false
    end

    -- guard against stacking hooks
    if AD.jobQueueHooked then
        return true
    end
    AD.jobQueueHooked = true

    AD.onCpFinished = Utils.overwrittenFunction(AD.onCpFinished, function(vehicle, superFunc, ...)
        if JobQueue:handleCpFinished(vehicle) then
            return
        end

        return superFunc(vehicle, ...)
    end)

    JobQueue.log("AutoDrive hook installed")
    return true
end

function JobQueue:loadMap()
    if not JobQueue.installHooks() then
        return
    end

    addConsoleCommand("jqCourses", "Lists Courseplay courses (folders without filter): jqCourses <words>", "consoleCourses", JobQueue)
    addConsoleCommand("jqDest", "Lists AutoDrive destinations: jqDest <words>", "consoleDestinations", JobQueue)
    addConsoleCommand("jqAdd", "Adds a job to the current vehicle: jqAdd <course words> | <destination words>", "consoleAdd", JobQueue)
    addConsoleCommand("jqList", "Shows the jobs of the current vehicle", "consoleList", JobQueue)
    addConsoleCommand("jqStart", "Starts the queue of the current vehicle", "consoleStart", JobQueue)
    addConsoleCommand("jqStop", "Clears and stops the queue of the current vehicle", "consoleStop", JobQueue)

    JobQueue.log("loaded")
end

-- persistence, same hook points as other savegame mods
Mission00.loadItemsFinished = Utils.appendedFunction(Mission00.loadItemsFinished, function()
    JobQueue.protected("loadFromXMLFile", JobQueue.loadFromXMLFile)
end)

FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function()
    JobQueue.protected("saveToXMLFile", JobQueue.saveToXMLFile)
end)

-- start fresh with the next mission
BaseMission.delete = Utils.prependedFunction(BaseMission.delete, function()
    JobQueue.queues = {}
    JobQueue.pending = {}
end)

addModEventListener(JobQueue)
