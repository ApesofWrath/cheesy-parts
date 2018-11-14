Sequel.migration do
  change do
    create_table(:milestones) do
      primary_key :id
      Integer :name, :null => false
      Integer :project_id, :null => false
      Date :deadline, :null => false
      Text :notes
      String :status, :null => false
    end
  end
end
