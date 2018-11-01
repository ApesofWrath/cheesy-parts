# Copyright 2012 Team 254. All Rights Reserved.
# @author pat@patfairbank.com (Patrick Fairbank)
#
# Represents a subteam for the team, such as mechanical or programming.

class Subteam < Sequel::Model
  one_to_many :tasks
end
