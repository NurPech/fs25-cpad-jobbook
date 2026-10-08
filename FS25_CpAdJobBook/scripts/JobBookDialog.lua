-- JobBookDialog
--
-- The window of the job book: shows the jobs of the vehicle the player sits in. Opened with the
-- CPADJOBBOOK_OPEN key (see JobQueue.registerActionEvents). Select an open job to remove it or move
-- it up or down, "Add" opens the AddJobDialog. The job that is running right now (first row, "now") can't be changed. Start begins
-- with the first open job, Stop keeps the open jobs but doesn't continue after the current course.

JobBookDialog = {}
local JobBookDialog_mt = Class(JobBookDialog, MessageDialog)

JobBookDialog.NAME = "JobBookDialog"
JobBookDialog.CONTROLS = {
    "titleText",
    "statusText",
    "jobList",
    "emptyText",
    "btnRemove",
    "btnUp",
    "btnDown",
    "btnStartStop",
}

function JobBookDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or JobBookDialog_mt)

    self.vehicle = nil
    self.rows = {}

    return self
end

function JobBookDialog:onLoad()
    JobBookDialog:superClass().onLoad(self)
    self:registerControls(JobBookDialog.CONTROLS)
end

function JobBookDialog:onGuiSetupFinished()
    JobBookDialog:superClass().onGuiSetupFinished(self)

    self.jobList:setDataSource(self)
    self.jobList:setDelegate(self)
end

function JobBookDialog:onOpen()
    JobBookDialog:superClass().onOpen(self)

    self:refresh()
end

function JobBookDialog:onClickBack()
    self:close()
end

---The row selected in the list, or nil.
function JobBookDialog:getSelectedRow()
    return self.rows[self.jobList.selectedIndex]
end

---The queue of the dialog's vehicle, or nil if it has none.
function JobBookDialog:getQueue()
    return self.vehicle ~= nil and JobQueue:getQueue(self.vehicle, false) or nil
end

function JobBookDialog:onClickAdd()
    AddJobDialog.show(self.vehicle, self.onAddJobClosed, self)
end

---Called when the AddJobDialog is closed: show the new jobs with the last one selected.
function JobBookDialog:onAddJobClosed()
    local queue = self:getQueue()
    if queue == nil then
        self:refresh()
        return
    end

    -- the running job (if any) is the first row, then the open jobs
    self:refresh(#queue.jobs + (queue.current ~= nil and 1 or 0))
end

function JobBookDialog:onClickRemove()
    local row = self:getSelectedRow()
    local queue = self:getQueue()
    if row == nil or row.jobIndex == nil or queue == nil then
        return
    end

    table.remove(queue.jobs, row.jobIndex)
    self:refresh(self.jobList.selectedIndex)
end

function JobBookDialog:onClickUp()
    self:moveSelected(-1)
end

function JobBookDialog:onClickDown()
    self:moveSelected(1)
end

---Moves the selected open job by one place and keeps it selected.
function JobBookDialog:moveSelected(direction)
    local row = self:getSelectedRow()
    local queue = self:getQueue()
    if row == nil or row.jobIndex == nil or queue == nil then
        return
    end

    local target = row.jobIndex + direction
    if target < 1 or target > #queue.jobs then
        return
    end

    queue.jobs[row.jobIndex], queue.jobs[target] = queue.jobs[target], queue.jobs[row.jobIndex]
    self:refresh(self.jobList.selectedIndex + direction)
end

---Start or stop, depending on whether the queue is running.
function JobBookDialog:onClickStartStop()
    local vehicle = self.vehicle
    local queue = self:getQueue()
    if vehicle == nil then
        return
    end

    if queue ~= nil and queue.running then
        JobQueue:stopQueue(vehicle, true)
        self:refresh(self.jobList.selectedIndex)
        return
    end

    local ok, message = JobQueue:startQueue(vehicle)
    if ok then
        self:close()
        return
    end

    self:refresh(self.jobList.selectedIndex)
    self.statusText:setText(message)
end

function JobBookDialog:onListSelectionChanged(list, section, index)
    self:updateButtons()
end

function JobBookDialog:updateButtons()
    local row = self:getSelectedRow()
    local queue = self:getQueue()
    local jobIndex = row ~= nil and row.jobIndex or nil
    local count = queue ~= nil and #queue.jobs or 0

    self.btnRemove:setDisabled(jobIndex == nil)
    self.btnUp:setDisabled(jobIndex == nil or jobIndex <= 1)
    self.btnDown:setDisabled(jobIndex == nil or jobIndex >= count)

    local running = queue ~= nil and queue.running
    self.btnStartStop:setText(g_i18n:getText(running and "jobBook_stop" or "jobBook_start"))
    self.btnStartStop:setDisabled(not running and count == 0)
end

---Rebuilds the rows from the queue of the vehicle and redraws the list. selectIndex is the row to
-- select afterwards (clamped to the list).
function JobBookDialog:refresh(selectIndex)
    self.rows = {}

    local vehicle = self.vehicle
    local queue = vehicle ~= nil and JobQueue:getQueue(vehicle, false) or nil

    if queue ~= nil then
        if queue.current ~= nil then
            table.insert(self.rows, { number = g_i18n:getText("jobBook_now"), job = queue.current })
        end

        for i, job in ipairs(queue.jobs) do
            table.insert(self.rows, { number = tostring(i), job = job, jobIndex = i })
        end
    end

    local name = vehicle ~= nil and JobQueue.getVehicleName(vehicle) or "?"
    local state = (queue ~= nil and queue.running) and g_i18n:getText("jobBook_running") or g_i18n:getText("jobBook_notStarted")
    self.statusText:setText(string.format("%s - %s", name, state))

    self.emptyText:setVisible(#self.rows == 0)
    self.jobList:reloadData()

    if #self.rows > 0 then
        if selectIndex == nil then
            -- the first open job, not the running one that can't be changed
            selectIndex = 1
            for i, row in ipairs(self.rows) do
                if row.jobIndex ~= nil then
                    selectIndex = i
                    break
                end
            end
        end

        self.jobList:setSelectedIndex(math.max(1, math.min(selectIndex, #self.rows)), true)
    end

    self:updateButtons()
end

---Data source of the list
function JobBookDialog:getNumberOfSections()
    return 1
end

function JobBookDialog:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function JobBookDialog:getTitleForSectionHeader(list, section)
    return nil
end

function JobBookDialog:getSectionHeaderHeight(list, section)
    return 0
end

function JobBookDialog:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then
        return
    end

    cell:getDescendantByName("cellNumber"):setText(row.number)
    cell:getDescendantByName("cellCourse"):setText(row.job.course.relative)
    cell:getDescendantByName("cellDestination"):setText(row.job.markerName or "?")
end

---Loads the dialog once per game start.
function JobBookDialog.register()
    g_gui:loadGui(JobQueue.modDirectory .. "gui/JobBookDialog.xml", JobBookDialog.NAME, JobBookDialog.new())
end

---Opens the dialog for the vehicle the player sits in. Does nothing if there is none.
function JobBookDialog.show()
    local gui = g_gui.guis[JobBookDialog.NAME]
    local vehicle = JobQueue.getControlledVehicle()

    if gui == nil or vehicle == nil or g_gui:getIsGuiVisible() then
        return
    end

    gui.target.vehicle = vehicle
    g_gui:showDialog(JobBookDialog.NAME)
end
