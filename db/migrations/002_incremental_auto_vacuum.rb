# database.rb switches to WAL before setting auto_vacuum, and once the header is written
# auto_vacuum only changes through a VACUUM. Without it incremental_vacuum is a no-op and the
# file never shrinks after pruning.
Sequel.migration do
  no_transaction

  up do
    unless fetch("PRAGMA auto_vacuum").get == 2
      run "PRAGMA auto_vacuum = INCREMENTAL"
      run "VACUUM"
    end
  end

  down {}
end
