package TestDbServer::Schema::Result::Template;
use parent 'TestDbServer::Schema::ResultBase';

__PACKAGE__->table('db_template');
__PACKAGE__->add_columns(qw(template_id name note owner sql_script create_time last_used_time));
__PACKAGE__->set_primary_key('template_id');
__PACKAGE__->has_many(databases => 'TestDbServer::Schema::Result::Database', 'template_id');

sub _create_table_sql_SQLite {
    q(
        CREATE TABLE IF NOT EXISTS db_template (
            template_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            name VARCHAR NOT NULL UNIQUE,
            owner VARCHAR NOT NULL,
            note VARCHAR,
            sql_script TEXT NOT NULL,
            create_time TIMESTAMP NOT NULL DEFAULT(datetime('now')),
            last_used_time TIMESTAMP NOT NULL DEFAULT(datetime('now'))
        )
    );
}

1;
