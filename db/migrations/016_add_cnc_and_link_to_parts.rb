Sequel.migration do
  change do
    alter_table(:parts) do
      add_column :link, String, :null => false
      add_column :cnc_part, Integer, :null => false
    end
  end
endF
