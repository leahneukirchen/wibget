# = WibGet -- a minimalist, but convenient Git web frontend
#
# Copyright (C) 2008 Christian Neukirchen <purl.org/net/chneukirchen>
# Licensed under the terms of the MIT license.

require 'rack'
require 'coset'
require "grit"

class WibRepos
  def initialize(repos)
    @repos = repos
    @map = Rack::URLMap.new(
      @repos.map { |name, location|
        wib = WibGet.new(File.expand_path(location))
        ["/" + name, Rack::Cascade.new([Rack::File.new(wib.repo.git.git_dir),
                                        wib])]
      } << ["/", method(:index)])
  end

  def call(env)
    @map.call(env)
  end

  def index(env)
    req = Rack::Request.new(env)
    res = Rack::Response.new
    res.write WibGet::HEADER
    res.write "<h1>WibGet repositories:</h1>"
    @repos.map { |name, location|
      res.write %{<li><a href="#{name}/">#{name}</a></li>}
    }
    res.finish
  end
end

class WibGet < Coset
  PER_PAGE = 10

  HEADER = <<'EOF'
<script src="http://ajax.googleapis.com/ajax/libs/jquery/1.2.6/jquery.min.js"></script>
<script>
jQuery(function($){
  $("pre").hide()
  $(".entry h2").click(function() {
    $(this).parent().find("pre").toggle()
  })
  $(".tree dd").hide()
  $(".tree dt").click(function() {
    $(this).next("dd").toggle()
  })
  $("#files").click(function() {
    if ($(".tree dd:hidden").length > 1)
      $(".tree dd").show()
    else
      $(".tree dd").hide()
  })
  $("#logs").click(function() {
    if ($(".entry pre:hidden").length > 1)
      $(".entry pre").show()
    else
      $(".entry pre").hide()
  })
})
</script>

<style>
body { font: 10px monospace; }

.entry h2 {
  font-weight: normal;
  white-space: pre;
}

h2 { clear: left; }
pre { background-color: #eee; }

dl, dt {
  margin: 0;
  padding: 0;
}
dd {
  margin: 0; 
  padding: 0 0 0 4em;
}

.info { color: #777; }
.del { color: red; }
.ins { color: green; }
</style>
EOF

  attr_accessor :repo

  def initialize(repo)
    @repo = Grit::Repo.new(repo)
    @dir = repo
  end
  
  def traverse(res, tree)
    res.write "<dl>"
    tree.contents.sort_by { |c| c.name.downcase }.each { |c|
      case c
      when Grit::Blob
        res.write "<dt><a href='#{c.id[0..6]}'>#{c.name}</a></dt>"
      when Grit::Tree
        res.write "<dt>#{c.name}/</dt>"
        res.write "<dd>"
        traverse(res, c)
        res.write "</dd>"
      else
        raise TypeError, "Unknown tree element: #{c.inspect}"
      end
    }
    res.write "</dl>"
  end

  GET("/") {
    run("/master", "GET")
  }

  GET("/{id}") {
    id = @repo.git.rev_parse({:verify => true}, @id)

    begin
      tree = @repo.tree(id)
    rescue RuntimeError
      blob = @repo.blob(id)
      
      res['Content-Type'] = blob.mime_type
      res.write blob.data
      return
    end

    res.write HEADER

    if tree.contents.empty?
      res.status = 404
      res.write "<h1>Not found: #{Rack::Utils.escape_html id}</h1>"
      return
    end

    @offset = [(req["offset"] || 0).to_i, 0].max
    log = @repo.git.log({ :cc => true,
                          :p => true,
                          :pretty => 'format:%s (%aN, %ar) %ai %h%n%b',
                          :shortstat => true,
                          :z => true,
                          :skip => @offset,
                          :max_count => PER_PAGE},
                        id)

    niceid = @repo.git.describe({ :contains => true,
                                  :always => true,
                                  :all => true,
                                  :abbrev => 7},
                                id)
    if @id != niceid
      res.write "<h1>#{@id} (#{niceid} = #{id})</h1>"
    else
      res.write "<h1>#{@id} (#{id})</h1>"
    end

    res.write '<h2>Heads: '
    heads = {}
    @repo.heads.sort_by { |head| head.name }.each { |head|
      commit = head.commit
      heads[head.name] = commit.id
      res.write %{<a href="#{head.name}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{head.name}</a> }
    }
    res.write "</h2>"

    unless @repo.tags.empty?
      res.write '<h2>Tags: '
      @repo.tags.sort_by { |tag| tag.name }.each { |tag|
        commit = tag.commit
        res.write %{<a href="#{tag.name}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{tag.name}</a> }
      }
      res.write "</h2>"
    end

    unless @repo.remotes.empty?
      res.write '<h2>Remotes: '
      @repo.remotes.sort_by { |remote| remote.name }.each { |remote|
        commit = remote.commit
        # Don't show remotes that are mere copie
        next  if heads[remote.name.split("/").last] == commit.id
        res.write %{<a href="#{commit.id[0..7]}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{remote.name}</a> }
      }
      res.write "</h2>"
    end
    
    res.write '<h2 id="files">Files:</h2>'
    
    res.write '<div class="tree">'
    traverse(res, tree)
    res.write '</div>'
    
    res.write '<div class="log">'
    res.write '<h2 id="logs">Change log:</h2>'
    c = 0
    entries = log.split("\0")
    entries.each_with_index { |desc, i|
      next  if desc =~ /\Adiff --/
      if entries[i+1] =~ /\Adiff --/
        diff = entries[i+1] || ""
      end
      c += 1
      desc.gsub!(/\A(.*) \((.*), (.*)\) (.*?) (\w+)$/, '<a href="\5">\5</a>: <strong>\1</strong> (\2, <span title="\4">\3</span>)')
      title, desc = desc.split("\n", 2)
      diff = Rack::Utils.escape_html diff
      diff.gsub!(/^-.*/, '<span class="del">\&</span>')
      diff.gsub!(/^\+.*/, '<span class="ins">\&</span>')
      if diff =~ /\Adiff --cc/
        puts "CC"
        diff.gsub!(/^ -.*/, '<span class="del">\&</span>')
        diff.gsub!(/^ \+.*/, '<span class="ins">\&</span>')
      end
      diff.gsub!(/^(diff|index|@@).*/, '<span class="info">\&</span>')
      res.write <<EOF
<div class="entry">
<h2>#{title}</h2>
<pre>#{desc}</pre>
<pre class="diff">#{diff}</pre>
</div>
EOF
    }
    res.write '</div>'

    if @offset > PER_PAGE
      res.write %{<a href="?offset=#{@offset-PER_PAGE}">&lt;&lt;</a>}
    elsif @offset > 0
      res.write %{<a href="?">&lt;&lt;</a>}
    else
      res.write "&lt;&lt;"
    end
    res.write " "
    if c >= PER_PAGE
      res.write %{<a href="?offset=#{@offset+PER_PAGE}">&gt;&gt;</a>}
    else
      res.write "&gt;&gt;"
    end
  }
end
