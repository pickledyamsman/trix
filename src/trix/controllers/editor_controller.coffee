#= require trix/controllers/abstract_editor_controller
#= require trix/controllers/input_controller
#= require trix/controllers/document_controller
#= require trix/controllers/toolbar_controller
#= require trix/models/composition
#= require trix/models/attachment_manager
#= require trix/models/undo_manager
#= require trix/models/selection_manager
#= require trix/observers/mutation_observer

class Trix.EditorController extends Trix.AbstractEditorController
  constructor: ->
    super

    @selectionManager = new Trix.SelectionManager @documentElement
    @selectionManager.delegate = this

    @composition = new Trix.Composition @document
    @composition.delegate = this

    @attachmentManager = new Trix.AttachmentManager @composition
    @attachmentManager.delegate = this

    @undoManager = new Trix.UndoManager @composition

    @inputController = new Trix.InputController @documentElement
    @inputController.delegate = this
    @inputController.responder = @composition

    @mutationObserver = new Trix.MutationObserver @documentElement
    @mutationObserver.delegate = this

    @toolbarController = new Trix.ToolbarController @toolbarElement
    @toolbarController.delegate = this
    @toolbarController.updateActions()

    @composition.loadDocument(@document)

    @documentController = new Trix.DocumentController @documentElement, @document
    @documentController.delegate = this
    @documentController.render()

    if @config.autofocus
      @documentController.focus()
      @setLocationRange([0,0]) unless @getLocationRange()

  # Composition delegate

  compositionDidChangeDocument: (document) ->
    @documentController.render()

  compositionDidChangeCurrentAttributes: (currentAttributes) ->
    @toolbarController.updateAttributes(currentAttributes)
    @toolbarController.updateActions()

  compositionWillSetLocationRange: ->
    @skipSelectionLock = true

  compositionShouldAcceptFile: (file) ->
    @delegate?.shouldAcceptFile?(file)

  compositionDidAddAttachment: (attachment) ->
    managedAttachment = @attachmentManager.manageAttachment(attachment)
    @delegate?.didAddAttachment?(managedAttachment)

  compositionDidEditAttachment: (attachment) ->
    @documentController.rerenderViewForObject(attachment)

  compositionDidRemoveAttachment: (attachment) ->
    managedAttachment = @attachmentManager.unmanageAttachment(attachment)
    @delegate?.didRemoveAttachment?(managedAttachment)

  compositionDidStartEditingAttachment: (attachment) ->
    @attachmentLocationRange = @document.getLocationRangeOfAttachment(attachment)
    @documentController.installAttachmentEditorForAttachment(attachment)
    @selectionManager.setLocationRange(@attachmentLocationRange)

  compositionDidStopEditingAttachment: (attachment) ->
    @documentController.uninstallAttachmentEditor()
    delete @attachmentLocationRange

  # Attachment manager delegate

  attachmentManagerDidRequestRemovalOfAttachment: (attachment) ->
    @removeAttachment(attachment)

  # Document controller delegate

  documentControllerWillRender: ->
    @mutationObserver.stop()
    @selectionManager.lock() unless @skipSelectionLock

  documentControllerDidRender: ->
    @mutationObserver.start()
    @selectionManager.unlock() unless @skipSelectionLock
    delete @skipSelectionLock
    @saveSerializedDocument()
    @toolbarController.updateActions()
    @delegate?.didRenderDocument?()

  documentControllerDidFocus: ->
    @toolbarController.hideDialog() if @dialogWantsFocus

  documentControllerDidSelectAttachment: (attachment) ->
    locationRange = @document.getLocationRangeOfAttachment(attachment)
    @composition.editAttachment(attachment)

  documentControllerWillUpdateAttachment: (attachment) ->
    @undoManager.recordUndoEntry("Edit Attachment", context: attachment.id, consolidatable: true)

  documentControllerDidRequestRemovalOfAttachment: (attachment) ->
    @removeAttachment(attachment)

  # Input controller delegate

  inputControllerWillPerformTyping: ->
    @undoManager.recordUndoEntry("Typing", context: @getLocationContext(), consolidatable: true)

  inputControllerWillCutText: ->
    @undoManager.recordUndoEntry("Cut")

  inputControllerWillPasteText: ->
    @undoManager.recordUndoEntry("Paste")

  inputControllerWillMoveText: ->
    @undoManager.recordUndoEntry("Move")

  inputControllerWillAttachFiles: ->
    @undoManager.recordUndoEntry("Drop Files")

  inputControllerWillStartComposition: ->
    @mutationObserver.stop()
    @selectionManager.lock()

  inputControllerWillEndComposition: ->
    @documentController.render()
    @selectionManager.unlock()
    @mutationObserver.start()

  inputControllerDidComposeCharacters: (composedString) ->
    @undoManager.recordUndoEntry("Typing", context: @getLocationContext(), consolidatable: true)
    @composition.insertString(composedString)

  # Selection manager delegate

  locationRangeDidChange: (locationRange) ->
    @composition.updateCurrentAttributes()
    if @attachmentLocationRange and not @attachmentLocationRange.isEqualTo(locationRange)
      @composition.stopEditingAttachment()
    @delegate?.didChangeSelection?()

  selectionManagerDidRequestBlockElements: ->
    @documentController.getBlockElements()

  # Mutation observer delegate

  elementDidMutate: (mutations) ->
    @composition.replaceHTML(@documentElement.innerHTML)

  # Toolbar controller delegate

  toolbarActions:
    undo:
      test: -> @undoManager.canUndo()
      perform: -> @undoManager.undo()
    redo:
      test: -> @undoManager.canRedo()
      perform: -> @undoManager.redo()
    link:
      test: -> @composition.canSetCurrentAttribute("href")

  toolbarCanInvokeAction: (actionName) ->
    @toolbarActions[actionName]?.test.call(this)

  toolbarDidInvokeAction: (actionName) ->
    @toolbarActions[actionName]?.perform.call(this)

  toolbarDidToggleAttribute: (attributeName) ->
    @undoManager.recordUndoEntry("Formatting", context: @getLocationContext(), consolidatable: true)
    @composition.toggleCurrentAttribute(attributeName)
    @documentController.focus()

  toolbarDidUpdateAttribute: (attributeName, value) ->
    @undoManager.recordUndoEntry("Formatting", context: @getLocationContext(), consolidatable: true)
    @composition.setCurrentAttribute(attributeName, value)
    @documentController.focus()

  toolbarWillShowDialog: (wantsFocus) ->
    @dialogWantsFocus = wantsFocus
    @composition.expandSelectionForEditing()
    @freezeSelection() if wantsFocus

  toolbarDidHideDialog: ->
    @documentController.focus()
    @thawSelection()
    delete @dialogWantsFocus

  # Selection management

  getLocationRange: ->
    @selectionManager.getLocationRange()

  setLocationRange: (start, end) ->
    @selectionManager.setLocationRange(start, end)

  setLocationRangeFromPoint: (point) ->
    @selectionManager.setLocationRangeFromPoint(point)

  getPosition: ->
    locationRange = @selectionManager.getLocationRange()
    @document.rangeFromLocationRange(locationRange)[0]

  setPosition: (position) ->
    locationRange = @document.locationRangeFromPosition(position)
    @selectionManager.setLocationRange(locationRange)

  currentPositionIsCursorTarget: ->
    @selectionManager.currentPositionIsCursorTarget()

  adjustPositionInDirection: (direction) ->
    distance = if direction is "backward" then -1 else 1
    @setPosition(@getPosition() + distance)

  expandLocationRangeInDirection: (direction) ->
    locationRange = @selectionManager.getLocationRange()
    [startPosition, endPosition] = @document.rangeFromLocationRange(locationRange)
    if direction is "backward"
      startPosition--
    else
      endPosition++
    startLocation = @document.locationRangeFromPosition(startPosition).start
    endLocation = @document.locationRangeFromPosition(endPosition).start
    @setLocationRange(startLocation, endLocation)

  expandSelectionInDirectionWithGranularity: (direction, granularity) ->
    @selectionManager.expandSelectionInDirectionWithGranularity(direction, granularity)

  freezeSelection: ->
    unless @selectionFrozen
      @selectionManager.lock()
      @composition.freezeSelection()
      @selectionFrozen = true

  thawSelection: ->
    if @selectionFrozen
      @composition.thawSelection()
      @selectionManager.unlock()
      delete @selectionFrozen

  preserveSelection: (block) ->
    @selectionManager.preserveSelection(block)

  getLocationContext: ->
    locationRange = @selectionManager.getLocationRange()
    if locationRange?.isCollapsed() then locationRange.index else locationRange

  # Private

  removeAttachment: (attachment) ->
    @undoManager.recordUndoEntry("Delete Attachment")
    @composition.removeAttachment(attachment)
