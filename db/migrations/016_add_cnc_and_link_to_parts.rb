Sequel.migration do
  change do
    alter_table(:parts) do
      add_column :gcode_link, String, :null => false
      add_column :drawing_link, String, :null => false
      add_column :cnc_part, Integer, :null => false
    end
  end
end
