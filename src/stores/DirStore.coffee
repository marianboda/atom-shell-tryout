fs = require 'fs'

_ = require 'lodash'
Reflux = require 'reflux'
I = require 'immutable'
async = require 'async'
Path = require 'path'

Actions = require '../actions'
DBS = require '../services/SQLiteService'
config = require '../config'
TreeUtils = require '../utils/TreeUtils'
ProcessService = require '../services/ProcessService'

dataStore =
  scanningPaths: []
  ignorePaths: []
  scannedFiles: 0
  photos: []
  dirTree: {name: 'root', items: []}
  files: 0
  selectedDir: null
  currentPhotos: []
  processingState: false
  processedFiles: 0
  scanStatus: null

  DBS: DBS
  init: ->
    @loadScanningPaths()
    @loadIgnorePaths()
    @loadPhotos()
    @loadDirs()

    @listenTo Actions.scan, @scan

    @listenTo Actions.process, ->
      ph = @photos
        .filter (i) -> return (not i.hash?) or i.hash? is ''
      console.log "ALL: #{@photos.length}, TO PROCESS: #{ph.length}"
      @processingState = true if ph.length > 0

      ph.forEach (i) =>
        ProcessService.queue(i).then (photo) =>
          @processedFiles++
          if @processedFiles is @photos.length
            @processingState = false
          @trigger()

    @listenTo Actions.stopProcess, ->
      ProcessService.killQueue()

    @listenTo Actions.selectDirectory, (dir) ->
      @currentPhotos = @photos.filter (item) -> item.dir is dir
      console.log 'dir sel: ' + dir, @currentPhotos.length
      @selectedDir = dir
      @trigger()

    @listenTo Actions.addDirectoryToLibrary, (paths) ->
      newPaths = _.without(paths, @scanningPaths)
      @scanningPaths = _.uniq(@scanningPaths.concat(newPaths).sort())
      @DBS.addScanningPath s for s in newPaths
      @trigger()

    @listenTo Actions.removeDirectoryFromLibrary, (path) ->
      @scanningPaths = _.without @scanningPaths, path
      @DBS.removeScanningPath path
      @trigger()

    @listenTo Actions.addIgnorePath, (paths) ->
      newPaths = _.without(paths, @ignorePaths)
      @ignorePaths = @ignorePaths.concat(newPaths).sort()
      @DBS.addIgnorePath s for s in newPaths
      @trigger()

    @listenTo Actions.removeIgnorePath, (path) ->
      @ignorePaths = _.without @ignorePaths, path
      @DBS.removeIgnorePath path
      @trigger()

  loadPhotos: ->
    @DBS.getFiles (err, data) =>
      @photos = _.sortBy(data, 'path')
      @processedFiles = @photos
        .filter (i) -> return i.hash?
        .length
      @trigger()

  loadScanningPaths: ->
    @DBS.getScanningPaths (err, data) =>
      @scanningPaths = data.map (item) -> item.path
      @trigger()

  loadIgnorePaths: ->
    @DBS.getIgnorePaths (err, data) =>
      @ignorePaths = data.map (item) -> item.path
      @trigger()

  loadDirs: ->
    @DBS.getDirs (err, data) =>
      @dirTree = TreeUtils.buildTree _.sortBy(data,'path'), null, null, 'name'
      @trigger()

  photoToDB: (photo) ->
    @DBS.addFile photo

  scan: ->
    @scannedFiles = 0
    @scanStatus = 'started'
    dirs = []

    processDir = (dirObject) ->
      walkQueue.push dirObject.path, (e, ob) ->
        dirs.push ob

    processFile = (fileObject) =>
      @photoToDB fileObject
      @scannedFiles += 1
      @trigger()

    ignorePaths = @ignorePaths
    walkQueue = async.queue (dirPath, callback) =>
      fs.readdir dirPath, (err, files) =>
        @scanStatus = dirPath

        thisDir =
          path: dirPath
          name: Path.basename(dirPath)
          files: []
          items: []
          unrecognizedCount: 0

        async.eachLimit files, 10,
          (f, eachCallback) ->
            filePath = dirPath + Path.sep + f
            fs.lstat filePath, (err, stat) ->
              if stat.isDirectory() and filePath not in ignorePaths
                processDir {path: filePath}
              if stat.isFile()
                if isRecognized(f)
                  thisDir.files.push f
                  processFile {name: f, dir: dirPath, path: filePath, stat: stat}
                else
                  thisDir.unrecognizedCount += 1
              eachCallback()
        , (err) =>
          callback(err, thisDir)
          @loadPhotos()
    ,2

    isRecognized = (item) ->
      Path.extname(item).substring(1).toLowerCase() in config.ACCEPTED_FORMATS

    walkQueue.drain = =>
      @scanStatus = 'All done'
      dirTree = TreeUtils.buildTree dirs, null, null, 'name'

      newTree = TreeUtils.transformPost dirTree, (item) ->
        subCountReducer = (field) ->
          (prev, current) -> prev + (current[field] ? 0)
        sumField = (node, field, initField) ->
          reducer = subCountReducer(field)
          node.items.reduce reducer, (node[initField] ? 0)

        item.filesCount = if item.files?.length? then item.files.length else 0
        item.deepFilesCount = sumField item, 'deepFilesCount', 'filesCount'
        item.deepUnrecognizedCount = sumField item, 'deepUnrecognizedCount', 'unrecognizedCount'

      TreeUtils.traverse newTree, @DBS.addDir
      @dirTree = newTree
      @trigger {}

    @scanningPaths.map (item) ->
      processDir {path: item}

module.exports = Reflux.createStore dataStore
