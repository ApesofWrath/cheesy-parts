class Task < Sequel::Model
  many_to_one :subteam

  # The list of possible subteams. Key: string stored in database, value: what is displayed to the user.
  SUBTEAMS = { "additiveman" => "Additive Manufacturing",
               "business" => "Business",
               "cad" => "CAD",
               "electrical" => "Electrical",
               "leadership" => "Leadership",
               "machining" => "Machining",
               "mechanical" => "Mechanical",
               "media" => "Media",
               "outreach" => "Outreach",
               "programming" => "Programming",
               "scouting" => "Scouting" }
end

