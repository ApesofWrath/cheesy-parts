Sequel.migration do
  change do
    alter_table(:order_items) do
      add_column :requested_by, String, :null => false
    end
  end
end
