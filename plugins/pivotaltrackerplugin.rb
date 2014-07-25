require 'pivotal-tracker'
PivotalTracker::Client.token = bot.config['pivotal_tracker_api_key']

class PivotalTrackerPlugin < CampfireBot::Plugin
  on_command  'pthelp', :pthelp
  on_command  'ptnew', :ptnew
  on_command  'ptassign', :ptassign
  on_command  'ptestimate', :ptestimate
  on_command  'ptstatus', :ptstatus
  on_command  'ptlist', :ptlist
  on_command  'ptproject', :ptproject
  on_message  Regexp.new("([0-9]{8})", Regexp::IGNORECASE), :standup

  def initialize
    @log = Logging.logger["CampfireBot::Plugin::PivotalTracker"]
    @project = PivotalTracker::Project.find(bot.config['pivotal_tracker_default_project'])
    @current_states = ['unstarted','started','delivered','finished','accepted','rejected','icebox','unscheduled']
    @story_types = ['feature','bug','chore']
    @thanks = ['dankie','merci','shukran','grazie','arigatô','khob kun','gracias','obrigado']
    @ignore_words_for_standup = ['estimate','assign','status']
  end
  
  def pthelp(m)
    m.speak(self.getname(m) + ", I understand these commands:")
    m.speak("!ptnew [feature|chore|bug] As a customer, I should be able to do something                  <-- create a new story")
    m.speak("!ptlist                  <-- lists stories, accepts optional name, state, or 'all'")
    m.speak("!ptestimate 75662668 3                  <-- assign 3 points to this story")
    m.speak("!ptassign 75662668 Boris Cosic                  <-- assign this story to Boris")
    m.speak("!ptstatus 75662668                  <-- get details for this story")
    m.speak("!ptproject                  <-- lists projects, accepts optional project ID to switch default project")
    m.speak("I'll also watch for story IDs and if I see a status update, I'll update PivotalTracker so you don't have to. You can start, finish, deliver, accept, reject, or icebox stories.")
  end
  
  def ptproject(m)
    if m[:message].match(/^\d+$/)
      new_project = PivotalTracker::Project.find(Integer(m[:message].strip))
      @project = new_project if new_project
      m.speak("OK "  + self.getname(m) + ", the default project is now " + @project.name + ".")
    else
      projects = PivotalTracker::Project.all
      m.speak("OK "  + self.getname(m) + ", here are all the projects in PivotalTracker:")
      projects.each do |project|
        m.speak(project.name + " (" + project.id.to_s + ")")
      end
    end
  end
  
  def ptnew(m)
    tokens = self.gettokens(m)
    type = tokens.shift
    if @story_types.any? { |story_type| story_type.include? type }
      name = tokens.collect {|piece| piece}.join(" ").strip 
      story = @project.stories.create(:name => name, :story_type => type, :requested_by => m[:person])
      m.speak("OK "  + self.getname(m) + ", I created that " + type + ". " + story.url)
    else
      m.speak("Sorry " + self.getname(m) + ", what kind of story did you want to add?")
      m.speak("!ptnew [feature|chore|bug] As a customer, I should be able to do something                  <-- create a new story")
    end
  end
  
  def ptlist(m)
    if m[:message].include?('all')
      stories = @project.stories.all(:current_state => (@current_states - ["accepted"]))
    elsif @current_states.any? { |state| m[:message].include? state }
      state_to_find = m[:message]
      state_to_find = 'unscheduled' if m[:message] == 'icebox'
      stories = @project.stories.all(:current_state => state_to_find)
      m.speak(self.getname(m) + ", these stories are all " + state_to_find + ":") if stories.length > 0
    elsif self.getusers.any? { |u| m[:message].include? u}
      stories = @project.stories.all(:owned_by => m[:message])      
      m.speak(self.getname(m) + ", these stories are assigned to " + m[:message] + ":") if stories.length > 0
    elsif @story_types.any? { |type| m[:message].include?(type) || m[:message].include?(type + "s")}
      type_to_find = m[:message].gsub(/s$/,'')
      stories = @project.stories.all(:story_type => type_to_find, :current_state => (@current_states - ["accepted"]))     
      m.speak(self.getname(m) + ", these " + type_to_find + "s are unfinished:") if stories.length > 0
    else
      stories = @project.stories.all(:owned_by => m[:person])
      m.speak(self.getname(m) + ", these stories are assigned to you:") if stories.length > 0
    end
    
    stories.each do |story|
      m.speak(story.name + " [" + story.story_type + "]" + (story.owned_by ? " owned by " + story.owned_by : "") + ", status is " + story.current_state + ". (" + story.url + ") ")
    end
    
    m.speak(self.getname(m) + ", there were no stories found.") if stories.length == 0
  end
  
  def ptestimate(m)
    story = self.ptupdate(m,'estimate')
    if story != nil
      m.speak("OK " + self.getname(m) + ", I gave \"" + story.name + "\" " + story.estimate + " point" + (story.estimate != 1  ? "s" : "") + " (" + story.url + ")")
    end
  end

  def ptassign(m)
    story = self.ptupdate(m,'owned_by')
    if story != nil
      m.speak("OK " + self.getname(m) + ", I assigned \"" + story.name + "\" to " + story.owned_by + " (" + story.url + ")")
    end
  end
  
  def ptstatus(m)
    tokens = self.gettokens(m)
    story = @project.stories.find(tokens.first)
    if story
      m.speak(story.name + " [" + story.story_type + "]" + (story.owned_by ? " owned by " + story.owned_by : "") + ", status is " + story.current_state + ". (" + story.url + ")")
      m.speak(story.description) if story.description.length > 0
    else
      m.speak("Sorry " + self.getname(m) + ", I couldn't find a story with the ID " + tokens.first)
    end
  end
  
  def standup(m)
    if @ignore_words_for_standup.any? { |word| m[:body].include? word } == false
      storyActions, storyErrors, story, storyStatus, msg = [], [], nil, nil, ''
      tokens = self.gettokens(m)
      tokens.each do |token|
        token = token.gsub(/[^\w\s]/,'').downcase
        if token =~ /^([0-9]{8})$/
          if story == nil
            storyId = token
            story = @project.stories.find(storyId)
          end
          if story != nil && storyStatus != nil
            storyActions << storyStatus + " \"" + story.name + "\" (" + story.url + ")"
            response = story.update({"current_state" => storyStatus})
            storyErrors << story.id.to_s + ': "' + response.errors.errors.first + '"' if response.errors.errors.length > 0
            storyId, storyStatus, story = nil, nil, nil
          end
        elsif @current_states.any? { |state| token.include?(state) || token.include?(state.slice(0..-3))}
          storyStatus = token
          storyStatus = 'unscheduled' if storyStatus == 'icebox'
          storyStatus = storyStatus + 'ed' if storyStatus[-2,2] != 'ed'
          if story != nil
            storyActions << storyStatus + " \"" + story.name + "\" (" + story.url + ")"
            response = story.update({"current_state" => storyStatus})
            storyErrors << story.id.to_s + ': "' + response.errors.errors.first + '"' if response.errors.errors.length > 0
            storyId, storyStatus, story = nil, nil, nil
          end
        end
      end
      
      if storyActions.length > 0
        actions = storyActions.collect {|action| action}.join ", " 
        actions = actions.reverse.sub(',',', and '.reverse).reverse
        msg = "OK " + self.getname(m) + ", I've " + actions + ". " + @thanks.sample.capitalize! + "!"
      end
      if storyErrors.length > 0
        errors = storyErrors.collect {|error| error}.join ", " 
        msg = msg + " But " if msg.length > 0
        msg = msg + "I have a problem, when trying the update I got " + errors
      end

      m.speak("I noticed a story ID but I'm not sure what to do with it.") if story && storyStatus == nil
      m.speak(msg) if msg.length > 0
    end
  end

  def ptupdate(m,value)
    tokens = self.gettokens(m)
    story = @project.stories.find(tokens.shift)
    msg = tokens.collect {|piece| piece}.join(" ").strip 
    response = story.update({value => msg})
    unless response.errors.errors.length > 0
      return story
    end
    m.speak("Sorry " + self.getname(m) + ', I got an error: "' + response.errors.errors.first + '"')
    return nil
  end
  
  def getname(m)
    return m[:person].partition(' ').first
  end
  
  def gettokens(m)
    return m[:message].split(/\s/)
  end
  
  def getusers
    bot.rooms[bot.rooms.keys[0]].users.map { |u| u.name }
  end
  
end