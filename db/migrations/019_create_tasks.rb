Sequel.migration do
  change do
    create_table(:tasks) do
      primary_key :id
      String :name, :null => false, :unique => true
      Integer :project_id, :null => false
      String :sub_name, :null => false
      Date :deadline, :null => false
      Date :start_date, :null => false
      String :milestone_id, :null => false
      String :assignee, :null => false
      Integer :per_comp, :null => false
      Integer :dep_task_id
      String :notes
    end
  end
end
