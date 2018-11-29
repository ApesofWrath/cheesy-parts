Sequel.migration do
  change do
    alter_table(:parts) do
      add_column :print_part, Integer, :null => false, :default => 0
      add_column :milestone_id, String, :null => false
    end
  end
end
