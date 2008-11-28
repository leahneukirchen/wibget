# = WibGet -- a minimalist, but convenient Git web frontend
#
# Copyright (C) 2008 Christian Neukirchen <purl.org/net/chneukirchen>
# Licensed under the terms of the MIT license.

require 'rack'
require 'coset'
require "grit"

class WibRepos
  def initialize(repos)
    @repos = repos.map { |name, dir|
      [name, dir, WibGet.new(File.expand_path(dir))]
    }

    @map = Rack::URLMap.new(
      @repos.map { |name, dir, wib|
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
    res.write WibGet::HEADER % "Index of WibGet repositories"
    res.write "<h1>WibGet repositories:</h1>"
    @repos.map { |name, dir, wib|
      res.write %{<li><a href="#{name}/">#{name}</a>, #{wib.repo.description}</li>}
    }
    res.write "</body></html>"
    res.finish
  end
end

class WibGet < Coset
  PER_PAGE = 10

  HEADER = <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <title>%s</title>
    <script src="http://ajax.googleapis.com/ajax/libs/jquery/1.2.6/jquery.min.js"></script>
    <script>
jQuery(function($){
  $(".entry h2").click(function() {
    $(this).parent().find("pre").toggleClass("hidden")
  })
  $(".entry h2 a").click(function(e) {
    e.stopPropagation()
  })
  $(".tree dt").click(function() {
    $(this).next("dd").toggleClass("hidden")
  })
  $("#files").click(function() {
    if ($(".tree dd.hidden").length > 1)
      $(".tree dd").removeClass("hidden")
    else
      $(".tree dd").addClass("hidden")
  })
  $("#logs").click(function() {
    if ($(".entry pre.hidden").length > 1)
      $(".entry pre").removeClass("hidden")
    else
      $(".entry pre").addClass("hidden")
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

.entry h2, .tree dt, #logs, #files {
  cursor: pointer;
}

.hidden {
  display: none;
}
    </style>
  </head>
  <body>
EOF

  attr_accessor :repo

  def initialize(repo)
    @repo = Grit::Repo.new(repo)
    @dir = repo
    @name = File.basename(@dir)
  end
  
  def traverse(res, tree)
    tree.contents.sort_by { |c| c.name.downcase }.each { |c|
      case c
      when Grit::Blob
        res.write "<div><a href='#{c.id[0..6]}'>#{c.name}</a></div>"
      when Grit::Tree
        res.write "<dl>"
        res.write "<dt>#{c.name}/</dt>"
        res.write "<dd class='hidden'>"
        traverse(res, c)
        res.write "</dd>"
        res.write "</dl>"
      else
        raise TypeError, "Unknown tree element: #{c.inspect}"
      end
    }
  end

  def rev2url(rev)
    rev.gsub("/", "--")
  end

  def url2rev(url)
    url.gsub("--", "/")
  end
  
  GET("/") {
    run("/master", "GET")
  }

  GET("/{id}") {
    @id = url2rev @id
    if @id =~ /\A\(([\w\/^~-]+)\)/
      topic = url2rev $1
      @id = $'
    end

    id = @repo.git.rev_parse({:verify => true}, @id)

    begin
      tree = @repo.tree(id)
    rescue RuntimeError
      blob = @repo.blob(id)
      
      res['Content-Type'] = blob.mime_type
      res.write blob.data
      return
    end

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
                        topic ? "^" + topic : "", id)

    niceid = @repo.git.describe({ :contains => true,
                                  :always => true,
                                  :all => true,
                                  :abbrev => 7},
                                id)
    if @id != niceid
      title = "#{@name}: #{@id} (#{niceid} = #{id})"
    else
      title = "#{@name}: #{@id} (#{id})"
    end

    res.write HEADER % title
    res.write "<h1>#{title}</h1>"

    unless @repo.description =~ /^Unnamed repository/
      res.write "<p>#{Rack::Utils.escape_html @repo.description}</p>"
    end

    res.write '<h2>Heads: '
    heads = {}
    @repo.heads.sort_by { |head| head.name }.each { |head|
      commit = head.commit
      heads[head.name] = commit.id
      res.write %{<a href="#{rev2url head.name}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{head.name}</a> }  rescue nil
    }
    res.write "</h2>"

    unless @repo.tags.empty?
      res.write '<h2>Tags: '
      @repo.tags.sort_by { |tag| tag.name }.each { |tag|
        commit = tag.commit
        res.write %{<a href="#{rev2url tag.name}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{tag.name}</a> }  rescue nil
      }
      res.write "</h2>"
    end

    unless @repo.remotes.empty?
      res.write '<h2>Remotes: '
      @repo.remotes.sort_by { |remote| remote.name }.each { |remote|
        commit = remote.commit
        # Don't show remotes that are mere copie
        next  if heads[remote.name.split("/").last] == commit.id
        res.write %{<a href="#{rev2url remote.name}" title="#{commit.authored_date.xmlschema} by #{commit.author}">#{remote.name}</a> }  rescue nil
      }
      res.write "</h2>"
    end
    
    res.write '<h2 id="files">Files:</h2>'
    
    res.write '<div class="tree">'
    traverse(res, tree)
    res.write '</div>'
    
    res.write '<div class="log">'
    res.write '<h2 id="logs">Change log '
    if topic
      res.write %{[<a href="#{rev2url @id}">full log</a>]}
    else
      res.write %{[<a href="(master)#{rev2url @id}">topic log</a>]}
    end
    res.write ':</h2>'
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
<pre class="hidden">#{desc}</pre>
<pre class="hidden diff">#{diff}</pre>
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

    res.write "  </body>"
    res.write "</html>"
  }
end
