{$, $$, View} = require 'atom-space-pen-views'
{CompositeDisposable, Emitter} = require 'atom'
LocalFile = require '../model/local-file'

Dialog = require './dialog'

fs = require 'fs'
os = require 'os'
async = require 'async'
util = require 'util'
path = require 'path'
Q = require 'q'
_ = require 'underscore-plus'
mkdirp = require 'mkdirp'
moment = require 'moment'

module.exports =
  class FilesView extends View

    @content: ->
      @div class: 'remote-edit-tree-view remote-edit-resizer tool-panel', 'data-show-on-right-side': false, =>
        @div class: 'remote-edit-wrap', =>
          @div class: 'remote-edit-info', click: 'clickInfo', =>
            @p class: 'remote-edit-server', =>
              @span class: 'remote-edit-server-type inline-block', 'FTP:'
              @span class: 'remote-edit-server-alias inline-block highlight', outlet: 'server_alias', 'unknown'
            @p class: 'remote-edit-folder text-bold', =>
              @span 'Folder: '
              @span outlet: 'server_folder', 'unknown'

          @div class: 'remote-edit-scroller', outlet: 'scroller', =>
            @ol class: 'tree-view full-menu list-tree focusable-panel', tabindex: -1, outlet: 'list'
          @div class: 'remote-edit-message', outlet: 'message'
        @div class: 'remote-edit-resize-handle', outlet: 'resizeHandle'

    initialize: (@host) ->
      @disposables = new CompositeDisposable
      @listenForEvents()

    connect: (connectionOptions = {}, connect_path = false) ->
      @path = if connect_path then connect_path else if atom.config.get('remote-edit.rememberLastOpenDirectory') and @host.lastOpenDirectory? then @host.lastOpenDirectory else @host.directory
      async.waterfall([
        (callback) =>
          if @host.usePassword and !connectionOptions.password?
            if @host.password == "" or @host.password == '' or !@host.password?
              async.waterfall([
                (callback) ->
                  passwordDialog = new Dialog({prompt: "Enter password"})
                  passwordDialog.toggle(callback)
              ], (err, result) =>
                connectionOptions = _.extend({password: result}, connectionOptions)
                @toggle()
                callback(null)
              )
            else
              callback(null)
          else
            callback(null)
        (callback) =>
          if !@host.isConnected()
            @setLoading("Connecting...")
            @host.connect(callback, connectionOptions)
          else
            callback(null)
        (callback) =>
          @populate(callback)
      ], (err, result) =>
        if err?
          console.error err
          if err.code == 450 or err.type == "PERMISSION_DENIED"
            @setError("You do not have read permission to what you've specified as the default directory! See the console for more info.")
          else if err.code is 2 and @path is @host.lastOpenDirectory
            # no such file, can occur if lastOpenDirectory is used and the dir has been removed
            @host.lastOpenDirectory = undefined
            @connect(connectionOptions)
          else if @host.usePassword and (err.code == 530 or err.level == "connection-ssh")
            async.waterfall([
              (callback) ->
                passwordDialog = new Dialog({prompt: "Enter password"})
                passwordDialog.toggle(callback)
            ], (err, result) =>
              @toggle()
              @connect({password: result})
            )
          else
            @setError(err)
      )

    getFilterKey: ->
      return "name"

    destroy: ->
      @panel.destroy() if @panel?
      @disposables.dispose()

    cancelled: ->
      @hide()
      @host?.close()
      @destroy()

    toggle: ->
      if @panel?.isVisible()
        @cancel()
      else
        @show()

    show: ->
      @panel ?= atom.workspace.addLeftPanel(item: this, visible: true)

    hide: ->
      @panel?.hide()

    viewForItem: (item) ->
      $$ ->
        @li class: 'list-item list-selectable-item two-lines', =>
          if item.isFile
            @div class: 'primary-line icon icon-file-text', item.name
          else if item.isDir
            @div class: 'primary-line icon icon-file-directory', item.name
          else if item.isLink
            @div class: 'primary-line icon icon-file-symlink-file', item.name
          if item.name != '..'
            @div class: 'secondary-line no-icon text-subtle text-smaller', "S: #{item.size}, M: #{item.lastModified}, P: #{item.permissions}"

    populate: (callback) ->
      async.waterfall([
        (callback) =>
          @setLoading("Loading...")
          @server_alias.html(if @host.alias then @host.alias else @host.hostname)
          @server_folder.html(@path)
          @host.getFilesMetadata(@path, callback)
        (items, callback) =>
          items = _.sortBy(items, 'isFile') if atom.config.get 'remote-edit.foldersOnTop'
          @setItems(items)
          callback(undefined, undefined)
      ], (err, result) =>
        @setError(err) if err?
        callback?(err, result)
      )

    populateList: ->
      super
      @setError path.resolve @path

    getNewPath: (next) ->
      if (@path[@path.length - 1] == "/")
        @path + next
      else
        @path + "/" + next

    updatePath: (next) =>
      @path = @getNewPath(next)
      @server_folder.html(@path)

    getDefaultSaveDirForHostAndFile: (file, callback) ->
      async.waterfall([
        (callback) ->
          fs.realpath(os.tmpDir(), callback)
        (tmpDir, callback) ->
          tmpDir = tmpDir + path.sep + "remote-edit"
          fs.mkdir(tmpDir, ((err) ->
            if err? && err.code == 'EEXIST'
              callback(null, tmpDir)
            else
              callback(err, tmpDir)
            )
          )
        (tmpDir, callback) =>
          tmpDir = tmpDir + path.sep + @host.hashCode() + '_' + @host.username + "-" + @host.hostname +  file.dirName
          mkdirp(tmpDir, ((err) ->
            if err? && err.code == 'EEXIST'
              callback(null, tmpDir)
            else
              callback(err, tmpDir)
            )
          )
      ], (err, savePath) ->
        callback(err, savePath)
      )

    openFile: (file) =>
      #@setLoading("Downloading file...")
      dtime = moment().format("HH:mm:ss DD/MM/YY")
      async.waterfall([
        (callback) =>
          @getDefaultSaveDirForHostAndFile(file, callback)
        (savePath, callback) =>
          savePath = savePath + path.sep + dtime.replace(/([^a-z0-9\s]+)/gi, '').replace(/([\s]+)/gi, '-') + "_" + file.name
          localFile = new LocalFile(savePath, file, dtime, @host)
          @host.getFile(localFile, callback)
      ], (err, localFile) =>
        if err?
          @setError(err)
          console.error err
        else
          @host.addLocalFile(localFile)
          uri = "remote-edit://localFile/?localFile=#{encodeURIComponent(JSON.stringify(localFile.serialize()))}&host=#{encodeURIComponent(JSON.stringify(localFile.host.serialize()))}"
          atom.workspace.open(uri, split: 'left')

          @host.close()
      )

    openDirectory: (dir) =>
      @setLoading("Opening directory...")
      throw new Error("Not implemented yet!")

    confirmed: (item) ->
      async.waterfall([
        (callback) =>
          if !@host.isConnected()
            dir = if item.isFile then item.dirName else item.path
            @connect({}, dir)
          else
            callback(null)
        (callback) =>
          if item.isFile
            @openFile(item)
          else if item.isDir
            @setItems()
            @updatePath(item.name)
            @host.lastOpenDirectory = item.path
            @host.invalidate()
            @populate()
          else if item.isLink
            if atom.config.get('remote-edit.followLinks')
              @filterEditorView.setText('')
              @setItems()
              @updatePath(item.name)
              @populate()
            else
              @openFile(item)
          else
            @setError("Selected item is neither a file, directory or link!")
      ], (err, savePath) ->
        callback(err, savePath)
      )

    clickInfo: (event, element) ->
      #console.log event
      #console.log element

    resizeStarted: =>
      $(document).on('mousemove', @resizeTreeView)
      $(document).on('mouseup', @resizeStopped)

    resizeStopped: =>
      $(document).off('mousemove', @resizeTreeView)
      $(document).off('mouseup', @resizeStopped)

    resizeTreeView: ({pageX, which}) =>
      return @resizeStopped() unless which is 1

      #if atom.config.get('tree-view.showOnRightSide')
      #  width = @outerWidth() + @offset().left - pageX
      #else
      width = pageX - @offset().left
      @width(width)

    resizeToFitContent: ->
      @width(1) # Shrink to measure the minimum width of list
      @width(@list.outerWidth())

    listenForEvents: ->
      #@list.on 'mousedown', ({target}) =>
      #  false if target is @list[0]

      @list.on 'mousedown', 'li', (e) =>
        if(e.which == 1)
          @confirmed($(e.target).closest('li').data('select-list-item'))
          e.preventDefault()
          false

      @on 'dblclick', '.remote-edit-resize-handle', =>
        @resizeToFitContent()

      @on 'mousedown', '.remote-edit-resize-handle', (e) => @resizeStarted(e)

      @disposables.add atom.commands.add 'atom-workspace', 'filesview:open', =>
        item = @getSelectedItem()
        if item.isFile
          @openFile(item)
        else if item.isDir
          @openDirectory(item)

    setItems: (@items=[]) ->
      @message.hide()
      return unless @items?

      @list.empty()
      if @items.length
        for item in items
          itemView = $(@viewForItem(item))
          itemView.data('select-list-item', item)
          @list.append(itemView)
      else
        @setError('No matches found')

    setError: (message='') ->
        @setLoading(message)

    setLoading: (message='') ->
      @message.empty().show().append("<ul class='background-message centered'><li>#{message}</li></ul>")
