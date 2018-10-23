Sequel.migration do
  change do
    alter_table(:parts) do
      add_column :assignee, String, :null => false
    end
  end
end

