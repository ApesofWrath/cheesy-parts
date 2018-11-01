require "pathological"

require_relative "../../models/subteam"

Sequel.migration do
  up do
    subteam = Subteam.new(:name => "AdditiveMan")
    subteam.save
    subteam = Subteam.new(:name => "Business")
    subteam.save
    subteam = Subteam.new(:name => "CAD")
    subteam.save
    subteam = Subteam.new(:name => "Electrical")
    subteam.save
    subteam = Subteam.new(:name => "Leadership")
    subteam.save
    subteam = Subteam.new(:name => "Machining")
    subteam.save
    subteam = Subteam.new(:name => "Mechanical")
    subteam.save
    subteam = Subteam.new(:name => "Media")
    subteam.save
    subteam = Subteam.new(:name => "Outreach")
    subteam.save
    subteam = Subteam.new(:name => "Programming")
    subteam.save
    subteam = Subteam.new(:name => "Scouting")
    subteam.save
  end
end
