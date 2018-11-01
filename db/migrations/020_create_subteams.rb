Sequel.migration do
  change do
    create_table(:subteams) do
      String :name, :null => false, :unique => true
    end
  end
end
