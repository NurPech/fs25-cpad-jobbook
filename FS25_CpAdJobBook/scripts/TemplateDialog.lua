-- TemplateDialog
--
-- Opened from the job book: the saved job lists (templates) of the savegame. "Save" stores the list
-- of the vehicle under a name, "Append" adds the jobs of the selected template to the queue of the
-- vehicle (any vehicle, so a list can be copied from one vehicle to another), "Delete" removes it.

TemplateDialog = {}
local TemplateDialog_mt = Class(TemplateDialog, MessageDialog)

TemplateDialog.NAME = "TemplateDialog"
TemplateDialog.MAX_NAME_LENGTH = 40
TemplateDialog.CONTROLS = {
    "statusText",
    "templateList",
    "emptyText",
    "btnAdd",
    "btnDelete",
}

function TemplateDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TemplateDialog_mt)

    self.vehicle = nil
    self.callback = nil
    self.callbackTarget = nil

    return self
end

function TemplateDialog:onLoad()
    TemplateDialog:superClass().onLoad(self)
    self:registerControls(TemplateDialog.CONTROLS)
end

function TemplateDialog:onGuiSetupFinished()
    TemplateDialog:superClass().onGuiSetupFinished(self)

    self.templateList:setDataSource(self)
    self.templateList:setDelegate(self)
end

function TemplateDialog:onOpen()
    TemplateDialog:superClass().onOpen(self)

    self.statusText:setText(g_i18n:getText("templates_hint"))
    self:refresh(1)
end

---Closes the dialog and tells the job book, which shows the changed queue.
function TemplateDialog:onClickBack()
    local callback, callbackTarget = self.callback, self.callbackTarget

    self:close()

    if callback ~= nil then
        callback(callbackTarget)
    end
end

---The template selected in the list, or nil.
function TemplateDialog:getSelectedTemplate()
    return JobQueue.templates[self.templateList.selectedIndex]
end

---Asks for a name with the text input dialog of the game, the name of the queue is the suggestion.
function TemplateDialog:onClickSave()
    if self.vehicle == nil then
        return
    end

    TextInputDialog.show(TemplateDialog.onNameEntered, self, JobQueue:getQueueName(self.vehicle) or "",
        g_i18n:getText("templates_savePrompt"), nil, TemplateDialog.MAX_NAME_LENGTH, g_i18n:getText("button_ok"))
end

function TemplateDialog:onNameEntered(text, clickOk)
    if not clickOk then
        return
    end

    local count, index, replaced = JobQueue:saveTemplate(self.vehicle, text)
    if count == nil then
        -- index holds the reason
        self.statusText:setText(g_i18n:getText(index == "name" and "templates_needName" or "templates_nothingToSave"))
        return
    end

    self:refresh(index)
    self.statusText:setText(string.format(g_i18n:getText(replaced and "templates_replaced" or "templates_saved"),
        JobQueue.templates[index].name, count))
end

---Appends the selected template to the queue of the vehicle and goes back to the job book.
function TemplateDialog:onClickAdd()
    local template = self:getSelectedTemplate()
    if template == nil or self.vehicle == nil then
        return
    end

    JobQueue:addTemplate(self.vehicle, template)
    self:onClickBack()
end

function TemplateDialog:onClickDelete()
    local index = self.templateList.selectedIndex
    local template = JobQueue.templates[index]
    if template == nil then
        return
    end

    table.remove(JobQueue.templates, index)
    self:refresh(index)
    self.statusText:setText(string.format(g_i18n:getText("templates_deleted"), template.name))
end

function TemplateDialog:onListSelectionChanged(list, section, index)
    self:updateButtons()
end

function TemplateDialog:updateButtons()
    local hasSelection = self:getSelectedTemplate() ~= nil

    self.btnAdd:setDisabled(not hasSelection)
    self.btnDelete:setDisabled(not hasSelection)
end

---Redraws the list and selects selectIndex (clamped to the list).
function TemplateDialog:refresh(selectIndex)
    local count = #JobQueue.templates

    self.emptyText:setVisible(count == 0)
    self.templateList:reloadData()

    if count > 0 then
        self.templateList:setSelectedIndex(math.max(1, math.min(selectIndex or 1, count)), true)
    end

    self:updateButtons()
end

---Data source of the list
function TemplateDialog:getNumberOfSections()
    return 1
end

function TemplateDialog:getNumberOfItemsInSection(list, section)
    return #JobQueue.templates
end

function TemplateDialog:getTitleForSectionHeader(list, section)
    return nil
end

function TemplateDialog:getSectionHeaderHeight(list, section)
    return 0
end

function TemplateDialog:populateCellForItemInSection(list, section, index, cell)
    local template = JobQueue.templates[index]
    if template == nil then
        return
    end

    local destinations = {}
    for _, job in ipairs(template.jobs) do
        table.insert(destinations, job.markerName or "?")
    end

    cell:getDescendantByName("cellName"):setText(template.name)
    cell:getDescendantByName("cellCount"):setText(tostring(#template.jobs))
    cell:getDescendantByName("cellContent"):setText(table.concat(destinations, ", "))
end

---Loads the dialog once per game start.
function TemplateDialog.register()
    g_gui:loadGui(JobQueue.modDirectory .. "gui/TemplateDialog.xml", TemplateDialog.NAME, TemplateDialog.new())
end

---Opens the dialog for the vehicle. callback(callbackTarget) is called when it is closed.
function TemplateDialog.show(vehicle, callback, callbackTarget)
    local gui = g_gui.guis[TemplateDialog.NAME]
    if gui == nil or vehicle == nil then
        return
    end

    gui.target.vehicle = vehicle
    gui.target.callback = callback
    gui.target.callbackTarget = callbackTarget
    g_gui:showDialog(TemplateDialog.NAME)
end
