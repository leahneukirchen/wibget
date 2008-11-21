#!/usr/bin/env rackup

require 'wibget'

run WibRepos.new("rack" => "~/projects/rack",
                 "trivium" => "~/projects/trivium2")
