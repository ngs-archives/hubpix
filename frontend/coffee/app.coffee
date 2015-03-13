API_BASE = 'https://api.github.com'

getAccessToken = -> $('meta[name=x-github-access-token]').attr 'content'

getAPI = (path, callback) ->
  cb = (data, status, jqXHR) ->
    nextPage = jqXHR.getResponseHeader('Link')?.match(/<([^>]+)>;\s*rel="next"/)?[1]
    callback data, nextPage?
    $.getJSON nextPage, cb if nextPage?
  $.getJSON API_BASE + path, cb

createListItem = (text, link = null, image = null) ->
  link ||= '/' + text
  imgTag = if image? then """<img src="#{image}">""" else ''
  $("""<a href="#{link}" class="list-group-item">#{imgTag}#{text}</a>""").appendTo '.list-group'

organizationIndex = (path) ->
  getAPI '/user', ({login, avatar_url}) ->
    createListItem login, null, avatar_url
    getAPI '/user/orgs', (res) ->
      $.each res, (i, {login, avatar_url}) ->
        createListItem login, '/orgs/' + login, avatar_url

repositoryIndex = (path) ->
  path = if path.indexOf('/orgs/') == 0 then "#{path}" else "/users#{path}"
  getAPI "#{path}/repos?type=owner", (res, hasMore) ->
    $.each res, (i, repo) ->
      if repo.permissions.push
        path = "#{repo.owner.login}/#{repo.name}"
        prefix = if repo.owner.type is 'Organization' then '/orgs/' else '/'
        createListItem path, prefix + path

branchIndex = (path) ->
  getAPI "/repos#{path.replace /^\/orgs/, ''}/branches", (res, hasMore) ->
    $.each res, (i, {name}) ->
      createListItem name, "#{path}/#{encodeURIComponent name}"

directoryIndex = (currentPath) ->
  getAPI currentPath.replace(/^\/(?:orgs\/)?/, '/repos/').replace(/([^\/]+)$/, "git/refs/heads/$1"), ({ object: {url} }) ->
    path = $("<a href='#{url}'>")[0].pathname.replace('/git/commits/', '/git/trees/') + '?recursive=1'
    getAPI path, ({tree}) ->
      $.each tree, (i, item) ->
        {type, path} = item
        if type is 'tree'
          createListItem path, "#{currentPath}/#{encodeURIComponent path}"

uploader = (currentPath) ->
  pathComponents = currentPath.replace(/^\/(orgs\/)?/, '').split '/'
  [user, repo, ref, path] = pathComponents
  ref = decodeURIComponent ref
  refAPIPath = "/repos/#{user}/#{repo}/git/refs/heads/#{ref}"
  browsingPath = decodeURIComponent path
  apiBase = "#{API_BASE}/repos/#{user}/#{repo}/git/"
  action = apiBase + 'blobs'
  createTreeAPI = apiBase + 'trees'
  createCommitAPI = apiBase + 'commits'
  updateRefAPI = API_BASE + refAPIPath
  dz = null
  $('#file-upload').dropzone
    dictDefaultMessage: '<i class="glyphicon glyphicon-cloud-upload"></i><br>Drop files here to upload'
    addRemoveLinks: yes
    acceptedFiles: 'image/png,image/jpeg,image/gif'
    init: ->
      dz = @
      dz.uploadFiles = (droppedFiles) ->
        shas = []
        files = [].concat droppedFiles
        do uploadNext = ->
          unless files.length > 0
            dz._finished droppedFiles, shas, null
            return
          file = files.pop()
          name = file.name
          reader = new FileReader()
          reader.onloadend = =>
            dz.emit "uploadprogress", file, 20, 10
            action = dz.element.action
            content = reader.result.replace /^data:[^;]+;base64,/, ''
            $.ajax({
              url: action
              method: 'POST'
              data: JSON.stringify { content, encoding: 'base64' }
            })
            .done ({sha}) ->
              dz.emit "uploadprogress", file, 100, 10
              shas.push sha
              $(file.previewElement).attr 'data-sha', sha
              uploadNext()
            , (xhr, status, err) ->
              dz._errorProcessing files, err?.message || dz.options.dictResponseError.replace("{{statusCode}}", xhr.status), xhr
          reader.readAsDataURL file
        no

  $('#file-upload').attr({action})
    .on 'submit', ->
      form = $ @
      input = form.find 'input[type=text]'
      input.prop 'disabled', yes
      btn = form.find 'button[type=submit]'
      btn.button('commiting').prop 'disabled', yes
      message = input.val()
      newTree = $('.dz-preview.dz-complete').map ->
        ele = $ @
        sha = ele.data 'sha'
        path = browsingPath + '/' + ele.find('[data-dz-name]').text()
        { sha, path, mode: '100644', type: 'blob' }
      .get()
      getAPI refAPIPath, ({object}) ->
        parentCommit = object.sha
        $.getJSON object.url, (res) ->
          {tree} = res
          base_tree = tree.sha
          tree = newTree
          params = { base_tree, tree }
          $.post createTreeAPI, JSON.stringify(params), (res) ->
            params = { parents: [parentCommit], tree: res.sha, message }
            $.post createCommitAPI, JSON.stringify(params), (res) ->
              params = { sha: res.sha }
              $.ajax({ url: updateRefAPI, method: 'PATCH', data: JSON.stringify(params) }).done (res) ->
                dz.removeAllFiles()
                do refreshThumbnails
                input.prop 'disabled', no
                btn.button('reset').prop 'disabled', no
      no
  do refreshThumbnails = ->
    getAPI "/repos/#{user}/#{repo}/contents/#{browsingPath}?ref=#{ref}", (res) ->
      $('.current-items').empty()
      res = res.filter ({ path }) -> /\.(png|jpg|gif)$/.test path
      row = null
      $.each res, (i, item) ->
        if i % 4 == 0
          row = $('<div class="row">').appendTo '.current-items'
        row.append """
        <div class="col-sm-6 col-md-3">
          <div class="thumbnail">
            <img src="#{item.download_url}" style="max-width:100%" alt="#{item.name}">
            <div class="caption">
              <p><b>#{item.name}</b></p>
              <p><input class="form-control" type="text" value="![#{item.name}](#{item.name})" onclick="this.select()" readonly></p>
            </div>
          </div>
        </div>
        """


routes =
  '/': [organizationIndex, 'Select organization']
  '/:user': [repositoryIndex, 'Select repository']
  '/:user/:repo': [branchIndex, 'Select branch']
  '/:user/:repo/:branch': [directoryIndex, 'Select directory to upload']
  '/:user/:repo/:branch/:path': [uploader, 'Upload']
  '/orgs/:org': [repositoryIndex, 'Select repository']
  '/orgs/:org/:repo': [branchIndex, 'Select branch']
  '/orgs/:org/:repo/:branch': [directoryIndex, 'Select directory to upload']
  '/orgs/:org/:repo/:branch/:path': [uploader, 'Upload']

updateBreadCrumbs = (paths) ->
  ol = $ 'ol.breadcrumb'
  last = paths.length - 1
  for i in [0..last]
    continue if paths[i] is 'orgs'
    text = if i == 0
      '<i class="glyphicon glyphicon-home"></i>'
    else
      decodeURIComponent paths[i]
    ol.append if i == last
      """<li class="active">#{text}</li>"""
    else
      console.info paths[0..i]
      """<li><a href="#{paths[0..i].join('/') || '/'}">#{text}</a></li>"""

handleRoute = ->
  if route = $('meta[name=x-route-path]').attr 'content'
    [fn, title] = routes[route]
    $('.page-header h1').text title
    path = document.location.pathname
    updateBreadCrumbs path.split '/'
    fn? path

Dropzone.options.fileUpload = no

$.ajaxSettings.beforeSend = (xhr) ->
  xhr.setRequestHeader 'Authorization', "token #{getAccessToken()}"

$ ->
  do handleRoute
  $('input[type=search]').on 'keyup', (e) ->
    text = $(@).val().toUpperCase()
    $('.list-group-item').each ->
      item = $ @
      if !text || item.text().toUpperCase().indexOf(text) isnt -1
        item.show()
      else
        item.hide()

