Sequel.migration do
  change do
    alter_table(:orders) do
      add_column :requested_by, String, :null => false
    end
  end
end
