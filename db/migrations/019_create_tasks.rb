Sequel.migration do
  change do
    create_table(:tasks) do
      primary_key :id
      String :name, :null => false, :unique => true
      Integer :project_id, :null => false
      String :subteam, :null => false
      Date :deadline, :null => false
      String :milestone_name, :null => false
      String :assignee, :null => false
      String :status, :null => false
    end
  end
end
