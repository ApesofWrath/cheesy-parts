# Copyright 2012 Team 254. All Rights Reserved.
# @author pat@patfairbank.com (Patrick Fairbank)
#
# Represents a single part or assembly in a project.

class Milestone < Sequel::Model
  one_to_many :project
  one_to_many :task
  one_to_many :part

  # The list of possible part statuses. Key: string stored in database, value: what is displayed to the user.
  STATUS_MAP = { "in_progress" => "In  progress",
                 "finished" => "Finished"
                }
end
