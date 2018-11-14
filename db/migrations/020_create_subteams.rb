Sequel.migration do
  change do
    create_table(:subteams) do
      String :name, :null => false, :unique => true
    end
    alter_table(:subteams) do
      drop_index PRIMARY
    end
  end
end
