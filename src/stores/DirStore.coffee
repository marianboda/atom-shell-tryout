fs = require 'fs'

_ = require 'lodash'
Reflux = require 'reflux'
I = require 'immutable'
async = require 'async'
Path = require 'path'
exec = require('child_process').exec

Actions = require '../actions'
DBS = require '../services/SQLiteService'
config = require '../config'
TreeUtils = require '../utils/TreeUtils'
ProcessService = require '../services/ProcessService'

createFilesCounts = (tree) ->
  newTree = TreeUtils.transformPost tree, (item) ->
    subCountReducer = (field) ->
      (prev, current) -> prev + (current[field] ? 0)
    sumField = (node, field, initField) ->
      reducer = subCountReducer(field)
      node.items.reduce reducer, (node[initField] ? 0)
    item.filesCount ?= 0
    item.deepFilesCount = sumField item, 'deepFilesCount', 'filesCount'
    item.deepUnrecognizedCount = sumField item, 'deepUnrecognizedCount', 'unrecognizedCount'
  newTree

dataStore =
  scanningPaths: []
  ignorePaths: []
  scannedFiles: 0
  photos: []
  dirTree: {name: 'root', items: []}
  files: 0
  selectedDir: null
  selectedId: 0
  currentPhotos: []
  processingState: false
  processedFiles: 0
  scannedCount: 0
  scanStatus: null
  processState: 'empty'
  cameras: [{id: 0, name: 'all'}]

  DBS: DBS
  init: ->
    @loadScanningPaths()
    @loadIgnorePaths()
    @loadPhotos()
    @loadDirs()

    @listenTo Actions.scan, @scan

    @listenTo Actions.process, (current = false) ->
      if @processState is 'paused'
        return ProcessService.resume()

      photos = if current then @currentPhotos else @photos
      ph = photos
        .filter (i) -> return (not i.hash?) or i.hash? is ''
      console.log "ALL: #{photos.length}, TO PROCESS: #{ph.length}"
      @processingState = true if ph.length > 0

      async.forEachOfLimit(ph, 10, (i, idx, cb) =>
        ProcessService.queue(i).then (photo) =>
          @updatePhoto photo
          @processedFiles++
          if @processedFiles is photos.length
            @processingState = false
          @trigger()
          cb()
        )
      @processState = 'running'

    @listenTo Actions.stopProcess, ->
      @processState = 'paused'
      ProcessService.pause()

    @listenTo Actions.openFile, (p) ->
      console.log('opening file', p)
      exec('open "'+p+'"', ->)

    @listenTo Actions.selectFile, (id) ->
      @selectedId = id
      @selectedPhoto = (@photos.filter (item) -> item.id is id)[0]
      @loadPhotoDetails id
      @trigger()

    @listenTo Actions.selectDirectory, (dir) ->
      # # deep:
      # @currentPhotos = (@photos.filter (item) -> item.dir.indexOf(dir) is 0)[0..100]
      @currentPhotos = (@photos.filter (item) -> item.dir is dir)[0..100]

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

  updatePhoto: (ph) ->
    idx = _.findIndex(@photos, (i) => i.id is ph.id)
    @photos[idx] = ph
    currIdx = _.findIndex(@currentPhotos, (i) => i.id is ph.id)
    if currIdx >= 0
      @currentPhotos[currIdx] = ph

  loadPhotos: ->
    @DBS.getFiles (err, data) =>
      @photos = _.sortBy(data, 'path')

      cameras = @photos.reduce((acc, el) =>
        exif = JSON.parse(el.exif)
        return acc unless exif? && (exif.Make? || exif.Model?)

        cam = "#{exif.Make} #{exif.Model}"
        if (acc.filter (i) => i.name is cam).length is 0
          acc.push({id: acc.length, name: cam})
        acc
      , [{id: 0, name: '-- ALL --'}])

      @cameras = _.sortBy cameras, 'name'
      @processedFiles = @photos
        .filter (i) -> return i.hash?
        .length
      dirPathCounts = @photos
        .map((i) => i.dir)
        .reduce((acc, el) =>
          acc[el] = if (acc[el]?) then acc[el]+1 else 1
          acc
        , {})
      dirPaths = Object.keys(dirPathCounts).map((i) =>
        path: i
        filesCount: dirPathCounts[i]
      )
      @updateDirTree(dirPaths)

  loadPhotoDetails: (id) ->
    return if @selectedPhoto.id isnt id
    @DBS.getFilesByHash @selectedPhoto.hash, (err, res) =>
      @selectedPhoto.copies = res
      @trigger()

  updateDirTree: (data) ->
    tree = TreeUtils.buildTree _.sortBy(data,'path'), null, null, 'name'
    @dirTree = createFilesCounts tree
    @trigger()

  loadScanningPaths: ->
    @DBS.getScanningPaths (err, data) =>
      console.log('scanning paths', err, data)
      @scanningPaths = data.map (item) -> item.path
      @trigger()

  loadIgnorePaths: ->
    @DBS.getIgnorePaths (err, data) =>
      @ignorePaths = data.map (item) -> item.path
      @trigger()

  loadDirs: ->
    return null
    @DBS.getDirs (err, data) =>
      @dirTree = TreeUtils.buildTree _.sortBy(data,'path'), null, null, 'name'
      @trigger()

  photoToDB: (photo) ->
    @DBS.addFile photo

  scan: ->
    console.time('scan')
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
          (f, eachCallback) =>
            filePath = dirPath + Path.sep + f
            fs.lstat filePath, (err, stat) ->
              if stat.isDirectory() and filePath not in ignorePaths
                processDir {path: filePath}
              if stat.isFile()
                if isRecognized(f)
                  thisDir.files.push f
                  processFile
                    name: f
                    dir: dirPath
                    path: filePath
                    size: stat.size
                    status: 0
                else
                  thisDir.unrecognizedCount += 1
              eachCallback()
            @scannedCount++

        , (err) =>
          callback(err, thisDir)
          # @loadPhotos()
    ,2

    isRecognized = (item) ->
      Path.extname(item).substring(1).toLowerCase() in config.ACCEPTED_FORMATS

    walkQueue.drain = =>
      @scanStatus = 'All done, going to build tree'
      dirTree = TreeUtils.buildTree dirs, null, null, 'name'
      newTree = createFilesCounts dirTree

      TreeUtils.traverse newTree, @DBS.addDir
      @dirTree = newTree
      console.timeEnd('scan')
      @scanStatus = 'All done'
      @trigger {}
      @loadPhotos()

    @scanningPaths.map (item) ->
      processDir {path: item}

module.exports = Reflux.createStore dataStore
