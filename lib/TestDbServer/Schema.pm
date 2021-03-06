package TestDbServer::Schema;
use parent 'DBIx::Class::Schema';

use TestDbServer::Exceptions;


__PACKAGE__->load_namespaces();

{
    my $MOJO_LOGGER;

    sub initialize {
        my $class = shift;
        my $app = shift;

        $app || Exception::RequiredParamMissing->throw(
                    error => __PACKAGE__ . '->initialize() requires a Mojolicious app object as a parameter',
                    params => [q($_[0])],
                );

        $MOJO_LOGGER = $app->log;
    }

    sub log {
        return $MOJO_LOGGER;
    }
}

sub connect {
    my $class = shift;

    $class->log || Exception::NotInitialized->throw( error => 'initialized() was not called' );

    my $self = $class->SUPER::connect(@_);
    if ($self) {
        $self->_initialize_sources();
    }
    return $self;
}

sub _initialize_sources {
    my $self = shift;

    my @sources = $self->sources();
    $self->log->info('Initializing ' . scalar(@sources) . ' sources');

    $self->enable_foreign_keys();

    foreach my $source ( @sources ) {
        $self->log->info("Initializing source $source");
        my $source_class = join('::', __PACKAGE__, 'Result', $source);
        $source_class->_create_table($self);
    }
}

# create_database(), search_database(), find_database(), delete_database()
# create_template(), search_template(), find_template(), delete_template()
foreach my $type ( qw( database template ) ) {
    _sub_creator($type, 'create');
    _sub_creator($type, 'search');

    my $find_sub = sub {
        my $self = shift;
        $self->resultset(ucfirst($type))->find(@_);
    };
    my $find_name = "find_${type}";

    my $delete_sub = sub {
        my($self, $id) = @_;
        $self->$find_name($id)->delete();
    };
    my $delete_name = "delete_${type}";

    do {
        no strict 'refs';
        *$find_name = $find_sub;
        *$delete_name = $delete_sub;
    };
}    

sub _sub_creator {
    my $entity_type = shift;
    my $resultset_method = shift;

    my $resultset_type = ucfirst($entity_type);

    my $sub = sub {
        my $self = shift;
        my %params = @_;
        $self->resultset($resultset_type)->$resultset_method(\%params);
    };

    my $method_name = "${resultset_method}_${entity_type}";
    do { no strict 'refs';
        *$method_name = $sub;
    };
}
        

sub create_database {
    my $self = shift;
    my %params = @_;

    return $self->resultset('Database')->create(\%params);
}

sub create_template {
    my $self = shift;
    my %params = @_;

    return $self->resultset('Template')->create(\%params);
}

# Ugly!
sub _driver_type {
    shift->storage->dbh->{Driver}->{Name};
}

sub sql_to_update_expire_column {
    my($self, $ttl) = @_;

    return $self->_driver_type eq 'SQLite'
            ? "datetime('now','+$ttl second')"  # SQLite
            : "now() + interval '$ttl second'"; # PostgreSQL
}

sub sql_to_update_last_used_column {
    my $self = shift;

    return $self->_driver_type eq 'SQLite'
            ? q(datetime('now'))
            : 'now()';
}

sub enable_foreign_keys {
    my $self = shift;
    if ($self->_driver_type eq 'SQLite') {
        $self->storage->dbh->do('PRAGMA foreign_keys = ON');
    }
}

sub search_expired_databases {
    my $self = shift;

    my $criteria = $self->_driver_type eq 'SQLite'
                    ? q(datetime('now'))
                    : q(now());

    return $self->resultset('Database')->search({ expire_time => { '<' => \$criteria }});
}
 
1;
