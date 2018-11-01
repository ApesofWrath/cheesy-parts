Sequel.migration do
  change do
    create_table(:tasks) do
      primary_key :id
      String :name, :null => false, :unique => true
      Integer :project_id, :null => false
      String :subteam, :null => false
      Date :deadline, :null => false
    end
  end
end
