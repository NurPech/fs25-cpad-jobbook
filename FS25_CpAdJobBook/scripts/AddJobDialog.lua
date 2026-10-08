-- AddJobDialog
--
-- Opened from the job book: pick a Courseplay course (left) and an AutoDrive destination (right),
-- each with a text filter (all words must be contained, like the console commands), and add them as
-- a job to the queue of the vehicle. The dialog stays open so several jobs can be added in a row.

AddJobDialog = {}
local AddJobDialog_mt = Class(AddJobDialog, MessageDialog)

AddJobDialog.NAME = "AddJobDialog"
AddJobDialog.CONTROLS = {
    "statusText",
    "courseInput",
    "destinationInput",
    "courseList",
    "destinationList",
}

function AddJobDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or AddJobDialog_mt)

    self.vehicle = nil
    self.callback = nil
    self.callbackTarget = nil

    self.courses = {}
    self.destinations = {}
    self.filteredCourses = {}
    self.filteredDestinations = {}

    return self
end

function AddJobDialog:onLoad()
    AddJobDialog:superClass().onLoad(self)
    self:registerControls(AddJobDialog.CONTROLS)
end

function AddJobDialog:onGuiSetupFinished()
    AddJobDialog:superClass().onGuiSetupFinished(self)

    for _, list in ipairs({ self.courseList, self.destinationList }) do
        list:setDataSource(self)
        list:setDelegate(self)
    end
end

function AddJobDialog:onOpen()
    AddJobDialog:superClass().onOpen(self)

    -- read the courses and destinations fresh, they change while playing
    self.courses = JobQueue.findCourses()
    self.destinations = JobQueue.findDestinations()

    self.courseInput:setText("")
    self.destinationInput:setText("")
    self:applyFilter(self.courseList, self.courses, "filteredCourses", "")
    self:applyFilter(self.destinationList, self.destinations, "filteredDestinations", "")

    self.statusText:setText(g_i18n:getText("addJob_hint"))
end

function AddJobDialog:onClickBack()
    local callback, callbackTarget = self.callback, self.callbackTarget

    self:close()

    if callback ~= nil then
        callback(callbackTarget)
    end
end

---Entry name that the filter is matched against.
local function getEntryName(entry)
    return entry.relative or entry.name
end

---Filters entries by text into self[resultKey], redraws the list and selects its first entry.
function AddJobDialog:applyFilter(list, entries, resultKey, text)
    local result = {}
    for _, entry in ipairs(entries) do
        if JobQueue.matchesWords(text, getEntryName(entry)) then
            table.insert(result, entry)
        end
    end

    self[resultKey] = result

    list:reloadData()
    if #result > 0 then
        list:setSelectedIndex(1, true)
    end
end

function AddJobDialog:onCourseFilterChanged(element, text)
    self:applyFilter(self.courseList, self.courses, "filteredCourses", text or "")
end

function AddJobDialog:onDestinationFilterChanged(element, text)
    self:applyFilter(self.destinationList, self.destinations, "filteredDestinations", text or "")
end

function AddJobDialog:onClickAdd()
    local course = self.filteredCourses[self.courseList.selectedIndex]
    local destination = self.filteredDestinations[self.destinationList.selectedIndex]

    if course == nil or destination == nil then
        self.statusText:setText(g_i18n:getText("addJob_selectBoth"))
        return
    end

    local position = JobQueue:addJob(self.vehicle, course, destination)

    self.statusText:setText(string.format(g_i18n:getText("addJob_added"), position, course.relative, destination.name))
end

---Data source of both lists
function AddJobDialog:getNumberOfSections()
    return 1
end

function AddJobDialog:getNumberOfItemsInSection(list, section)
    if list == self.courseList then
        return #self.filteredCourses
    end

    return #self.filteredDestinations
end

function AddJobDialog:getTitleForSectionHeader(list, section)
    return nil
end

function AddJobDialog:getSectionHeaderHeight(list, section)
    return 0
end

function AddJobDialog:populateCellForItemInSection(list, section, index, cell)
    local entries = list == self.courseList and self.filteredCourses or self.filteredDestinations
    local entry = entries[index]
    if entry == nil then
        return
    end

    cell:getDescendantByName("cellName"):setText(getEntryName(entry))
end

---Loads the dialog once per game start.
function AddJobDialog.register()
    g_gui:loadGui(JobQueue.modDirectory .. "gui/AddJobDialog.xml", AddJobDialog.NAME, AddJobDialog.new())
end

---Opens the dialog for the vehicle. callback(callbackTarget) is called when it is closed.
function AddJobDialog.show(vehicle, callback, callbackTarget)
    local gui = g_gui.guis[AddJobDialog.NAME]
    if gui == nil or vehicle == nil then
        return
    end

    gui.target.vehicle = vehicle
    gui.target.callback = callback
    gui.target.callbackTarget = callbackTarget
    g_gui:showDialog(AddJobDialog.NAME)
end
