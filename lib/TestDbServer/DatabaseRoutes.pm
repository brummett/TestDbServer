package TestDbServer::DatabaseRoutes;
use Mojo::Base 'Mojolicious::Controller';

use Try::Tiny;

use TestDbServer::Utils;
use TestDbServer::Command::CreateDatabaseFromTemplate;
use TestDbServer::Command::DeleteDatabase;

sub list {
    my $self = shift;

    $self->_remove_expired_databases();

    my $params = $self->req->params->to_hash;
    my $databases = %$params
                    ? $self->app->db_storage->search_database(%$params)
                    : $self->app->db_storage->search_database;

    my(@ids, @render_args);
    @render_args = ( json => \@ids );
    try {
        while (my $db = $databases->next) {
            push @ids, $db->database_id;
        }
    }
    catch {
        if (ref($_)
            and
            $_->isa('DBIx::Class::Exception')
            and
            $_ =~ m/(no such column: \w+)/
        ) {
            @render_args = ( status => 400, text => $1 );
        } else {
            die $_;
        }
    }
    finally {
        $self->render(@render_args);
    };
}

sub get {
    my $self = shift;
    my $id = $self->stash('id');

    $self->_remove_expired_databases();

    my $schema = $self->app->db_storage();
    my $database = $schema->find_database($id);
    if ($database) {
        $self->render(json => _hashref_for_database_obj($database));
    } else {
        $self->render_not_found;
    }
}

sub _remove_expired_databases {
    my $self = shift;

    my $schema = $self->app->db_storage;

    my $database_set = $schema->search_expired_databases();
    while (my $database = $database_set->next()) {
        try {
            $schema->txn_do(sub {
                $self->app->log->info('expiring database '.$database->database_id);
                my $cmd = TestDbServer::Command::DeleteDatabase->new(
                                schema => $schema,
                                database_id => $database->database_id,
                            );
                $cmd->execute();
            });
        }
        catch {
            $self->app->log->error("expire database ".$database->database_id.": $_");
        };
    }
}

sub _hashref_for_database_obj {
    my $database = shift;

    my %h;
    @h{'id','host','port','name','owner','created','expires','template_id'}
        = map { $database->$_ } qw( database_id host port name owner create_time expire_time template_id );
    return \%h;
}

sub create {
    my $self = shift;

    if (my $template_id = $self->req->param('based_on')) {
        $self->_create_database_from_template($template_id);

    } elsif (my $owner = $self->req->param('owner')) {
        $self->_create_new_database($owner);

    } else {
        $self->render_not_found;
    }
}

sub _create_new_database {
    my($self, $owner) = @_;

    $self->_create_database_common(sub {
            my($host, $port) = $self->app->host_and_port_for_created_database();
            my $cmd = TestDbServer::Command::CreateDatabase->new(
                            owner => $owner,
                            template_id => undef,
                            host => $host,
                            port => $port,
                            superuser => $self->app->configuration->db_user,
                            schema => $self->app->db_storage,
                    );
        });
}

sub _create_database_from_template {
    my($self, $template_id) = @_;

    $self->_create_database_common(sub {
            my($host, $port) = $self->app->host_and_port_for_created_database();
            TestDbServer::Command::CreateDatabaseFromTemplate->new(
                            template_id => $template_id,
                            host => $host,
                            port => $port,
                            superuser => $self->app->configuration->db_user,
                            schema => $self->app->db_storage,
                    );
        });
}

sub _create_database_common {
    my($self, $cmd_creator_sub) = @_;

    my $schema = $self->app->db_storage;

    my($database, $return_code);
    try {
        $schema->txn_do(sub {
            my $cmd = $cmd_creator_sub->();
            $database = $cmd->execute();
        });
    }
    catch {
        if (ref($_)
                && ( $_->isa('Exception::TemplateNotFound') || $_->isa('Exception::CannotOpenFile'))
        ) {
            $return_code = 404;

        } else {
            $self->app->log->error("_create_database_from_template: $_");
            die $_;
        }
    };

    if ($database) {
        my $response_location = TestDbServer::Utils::id_url_for_request_and_entity_id($self->req, $database->database_id);
        $self->res->headers->location($response_location);

        $self->render(status => 201, json => _hashref_for_database_obj($database));

    } else {
        $self->rendered($return_code);
    }
}

sub delete {
    my $self = shift;
    my $id = $self->stash('id');

    my $schema = $self->app->db_storage;
    my $return_code;
    try {
        my $cmd = TestDbServer::Command::DeleteDatabase->new(
                        database_id => $id,
                        schema => $schema,
                    );
        $schema->txn_do(sub {
            $cmd->execute();
            $return_code = 204;
        });
    }
    catch {
        if (ref($_) && $_->isa('Exception::DatabaseNotFound')) {
            $return_code = 404;
        } elsif (ref($_) && $_->isa('Exception::CannotDropDatabase')) {
            $return_code = 409;
        } else {
            $self->app->log->error("delete database: $_");
            die $_;
        }
    };

    $self->rendered($return_code);
}

sub patch {
    my $self = shift;
    my $id = $self->stash('id');

    my $schema = $self->app->db_storage;

    my($return_code, $database);
    try {
        my $ttl = $self->req->param('ttl');
        if (! $ttl or $ttl < 1) {
            Exception::RequiredParamMissing->throw(params => ['ttl']);
        }
        my $update_expire_sql = $schema->sql_to_update_expire_column($ttl);

        $schema->txn_do(sub {
            $database = $schema->find_database($id);
            unless ($database) {
                Exception::DatabaseNotFound->throw(database_id => $id);
            }
            $database->update({ expire_time => \$update_expire_sql});

        });
        $return_code = 200;
    }
    catch {
        if (ref($_) && $_->isa('Exception::RequiredParamMissing')) {
            $return_code = 400;

        } elsif (ref($_) && $_->isa('Exception::DatabaseNotFound')) {
            $return_code = 404;

        } else {
            $self->app->log->error("delete database: $_");
            die $_;
        }
    };

    if ($database) {
        my $response_location = TestDbServer::Utils::id_url_for_request_and_entity_id($self->req, $database->database_id);
        $self->res->headers->location($response_location);

        $self->render(status => 200, json => _hashref_for_database_obj($database));

    } else {
        $self->rendered($return_code);
    }
}

1;
