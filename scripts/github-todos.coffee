# Configuration:
#   HUBOT_GITHUB_TODOS_REPO
#   HUBOT_GITHUB_TOKEN
#   HUBOT_GITHUB_USER_<NAME>
#   HUBOT_GITHUB_USER_<NAME>_TOKEN
#
# Notes:
#   HUBOT_GITHUB_TODOS_REPO = 'username/reponame' (separate multiple with commas, first one is primary)
#   HUBOT_GITHUB_TOKEN = oauth token (we use a "dobthubot" github account)
#   HUBOT_GITHUB_USER_ADAM = 'adamjacobbecker'
#   HUBOT_GITHUB_USER_ADAM_TOKEN = adamjacobbecker's oauth token
#
#   Individual users' oauth tokens are opt-in, but if you choose
#   not to add them, you'll end up notifying yourself when you
#   add a issue.
#
#   You'll need to create 'done', 'trash', 'upcoming', 'shelf', and 'current' labels.
#
# Commands:
#   hubot add issue <text> #todos
#   hubot put issue <id> in milestone <id>
#   hubot ask <user|everyone> to <text> #todos
#   hubot assign <id> to <user> #todos
#   hubot assign <user> to <id> #todos
#   hubot finish <id> #todos
#   hubot reopen <id> #todos
#   hubot i'll work on <id> #todos
#   hubot what am i working on #todos
#   hubot what is <user|everyone> working on #todos
#   hubot work on <id> #todos
#   hubot work on <text> #todos
#   hubot comment on issue <id> <text> #todos
#   hubot show milestones #todos
#   hubot add milestone <id> to issue <id> #todos
#   hubot show issues in milestones <id> #todos
#
# License:
#   MIT

_  = require 'underscore'
_s = require 'underscore.string'
async = require 'async'
moment = require 'moment'

log = (msgs...) ->
  console.log(msgs)

doubleUnquote = (x) ->
  _s.unquote(_s.unquote(x), "'")

class GithubTodosSender

  @ISSUE_BODY_SEPARATOR = ' body:'

  constructor: (robot) ->
    @robot = robot
    @github = require("githubot")(@robot)
    @allRepos = (process.env['HUBOT_GITHUB_TODOS_REPO'] || '').split(',') # default to empty string for tests
    @primaryRepo = @allRepos[0]

  getGithubUser: (userName) ->
    log "Getting GitHub username for #{userName}"
    process.env["HUBOT_GITHUB_USER_#{userName.split(' ')[0].toUpperCase()}"]

  getGithubToken: (userName) ->
    log "Getting GitHub token for #{userName}"
    process.env["HUBOT_GITHUB_USER_#{userName.split(' ')[0].toUpperCase()}_TOKEN"]

  optionsFor: (msg) ->
    options = {}

    if (x = @getGithubToken(msg.message.user.name))
      options.token = x

    options

  getIssueText: (issue, opts = {}) ->
    str = "#{opts.prefix || ''}"

    if opts.includeAssignee
      str += "#{issue.assignee?.login} - "

    if !issue.url.match(@primaryRepo)
      str += "#{issue.url.split('repos/')[1].split('/issues')[0]} "

    str += "##{issue.number} #{issue.title} - #{issue.html_url}"

    str

  getMilestoneText: (milestone, opts = {}) ->
    repoName = milestone.url.split('repos/')[1].split('/milestones')[0]
    milestoneIssuesUrl = "https://github.com/#{repoName}/issues?milestone=#{milestone.number}&state=open"
    dueDateText = if milestone.due_on then moment(milestone.due_on).fromNow(true) else "No due date"

    """
      #{repoName} #{milestone.title} - #{dueDateText} - #{milestoneIssuesUrl}
    """

  addIssueEveryone: (msg, issueBody, opts) ->
    userNames = {}

    for k, v of process.env
      if (x = k.match(/^HUBOT_GITHUB_USER_(\S+)$/)?[1]) && (k != "HUBOT_GITHUB_USER_#{msg.message.user.name.split(' ')[0].toUpperCase()}")
        userNames[x] = v unless x.match(/hubot/i) or x.match(/token/i) or (v in _.values(userNames))

    for userName in _.keys(userNames)
      @addIssue(msg, issueBody, userName, opts)

  addIssue: (msg, issueBody, userName, opts = {}) ->
    if userName.toLowerCase() in ['all', 'everyone']
      return @addIssueEveryone(msg, issueBody, opts)

    [title, body] = doubleUnquote(issueBody)
                    .replace(/\"/g, '')
                    .split(GithubTodosSender.ISSUE_BODY_SEPARATOR)

    sendData =
      title: title
      body: body || ''
      assignee: @getGithubUser(userName)
      labels: [opts.label || 'upcoming']

    if opts.footer && _.isEmpty(@optionsFor(msg))
      sendData.body += "\n\n(added by #{@getGithubUser(msg.message.user.name) || 'unknown user'}. " +
                   "remember, you'll need to bring them in with an @mention.)"

    log "Adding issue", sendData

    @github.withOptions(@optionsFor(msg)).post "repos/#{@primaryRepo}/issues", sendData, (data) =>
      msg.send @getIssueText(data, prefix: "Added: ")

  closeIssue: (msg, issueId, opts = {}) ->
      sendData =
        state: 'closed'

      log "Closing issue", sendData

      @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
        if _.find(data.labels, ((l) -> l.name.toLowerCase() == newLabel.toLowerCase()))
          msg.send @getIssueText(data, prefix: "Closed issue: ")

  reopenIssue: (msg, issueId, opts = {}) ->
      sendData =
        state: 'open'

      log "Opening issue", sendData

      @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
        if _.find(data.labels, ((l) -> l.name.toLowerCase() == newLabel.toLowerCase()))
          msg.send @getIssueText(data, prefix: "Reopened issue: ")

  commentOnIssue: (msg, issueId, body, opts = {}) ->
    sendData =
      body: body

    log "Commenting on issue", sendData

    @github.withOptions(@optionsFor(msg)).post "repos/#{@primaryRepo}/issues/#{issueId}/comments", sendData, (data) ->
      # Nada

  assignIssue: (msg, issueId, userName, opts = {}) ->
    sendData =
      assignee: @getGithubUser(userName)

    log "Assigning issue", sendData

    @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
      msg.send @getIssueText(data, prefix: "Assigned to #{data.assignee.login}: ")

  addIssueToMilestone: (msg, milestoneId, issueId, opts = {}) ->
    sendData =
      milestone: milestoneId

    log "Adding issue to milestone", sendData

    @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
      msg.send @getIssueText(data, prefix: "Added to #{data.milestone.url}: ")

  showIssues: (msg, userName, label, opts = {}) ->
    queryParams =
      assignee: if userName.toLowerCase() == 'everyone' then '*' else @getGithubUser(userName)
      labels: label || ""
      milestone: opts.milestoneId || "*"

    log "Showing issues", queryParams

    showIssueFunctions = []

    for repo in @allRepos
      do (repo) =>
        showIssueFunctions.push( (cb) =>
          @github.get "repos/#{repo}/issues", queryParams, (data) ->
            cb(null, data)
        )

    async.parallel showIssueFunctions, (err, results) =>
      log("ERROR: #{err}") if err
      allResults = [].concat.apply([], results)

      if _.isEmpty allResults
          msg.send "No issues found."
      else
        msg.send _.map(allResults, ((issue) => @getIssueText(issue, { includeAssignee: queryParams.assignee == '*' }))).join("\n")

  showMilestones: (msg, repoName) ->
    queryParams =
      state: 'open'

    log "Showing milestones", queryParams

    showMilestoneFunctions = []

    selectedRepos = if repoName == 'all'
      @allRepos
    else
      _.filter @allRepos, (repo) ->
        repo.split('/')[1].match(repoName)

    for repo in selectedRepos
      do (repo) =>
        showMilestoneFunctions.push( (cb) =>
          @github.get "repos/#{repo}/milestones", queryParams, (data) ->
            cb(null, data)
        )

    async.parallel showMilestoneFunctions, (err, results) =>
      log("ERROR: #{err}") if err
      allResults = [].concat.apply([], results)

      allResults = _.sortBy allResults, (r) ->
        r.due_on || "9"

      if _.isEmpty allResults
          msg.send "No milestones found."
      else
        msg.send _.map(allResults, ((milestone) => @getMilestoneText(milestone))).join("\n")

module.exports = (robot) ->
  robot.githubTodosSender = new GithubTodosSender(robot)

  robot.respond /add milestone (\d+) to issue (\d+)/i, (msg) ->
    robot.githubTodosSender.addIssueToMilestone msg, msg.match[1], msg.match[2]

  robot.respond /add issue (.*)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[1], msg.message.user.name

  robot.respond /work on ([A-Z\'\"][\s\S\d]+)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[1], msg.message.user.name, label: 'current', footer: true

  robot.respond /ask (\S+) to (.*)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[2], msg.match[1], footer: true

  robot.respond /comment on issue (\d+) (.*)/i, (msg) ->
    robot.githubTodosSender.commentOnIssue msg, msg.match[1], msg.match[2]

  robot.respond /finish (\d+)/i, (msg) ->
    if (comment = msg.match[2])
      robot.githubTodosSender.commentOnIssue msg, msg.match[1], msg.match[2]

    robot.githubTodosSender.closeIssue msg, msg.match[1]

  robot.respond /reopen (\d+)/i, (msg) ->
    if (comment = msg.match[2])
      robot.githubTodosSender.commentOnIssue msg, msg.match[1], msg.match[2]

    robot.githubTodosSender.reopenIssue msg, msg.match[1], ''

  robot.respond /what am i working on\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.message.user.name, ''

  robot.respond /what(['|’]s|s|\sis) (\S+) working on\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.match[2], ''

  robot.respond /assign \#?(\d+) to (\S+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[1], msg.match[2]

  robot.respond /assign (\S+) to \#?(\d+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[2], msg.match[1]

  robot.respond /i(['|’]ll|ll) work on \#?(\d+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[2], msg.message.user.name

  robot.respond /show milestones(\s*)$/i, (msg) ->
    robot.githubTodosSender.showMilestones msg, 'all'

  robot.respond /show issues in milestone (\d+)/i, (msg) ->
    robot.githubTodosSender.showIssues msg, 'everyone', ''

  robot.respond /thank you(.*)/i, (msg) ->
    msg.send "You're welcome"

  robot.hear /hipster/i, (msg) ->
    msg.send "(hipster)"

  robot.respond /(do|kill|make|create|destroy) (.*)/i, (msg) ->
    msg.send "I can't #{msg.match[1]} #{msg.match[2]}".replace /me/i, "you"

  robot.respond /(dance|rejoice)(.*)/i, (msg) ->
    msg.send "(dance)"
