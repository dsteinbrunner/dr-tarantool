use utf8;
use strict;
use warnings;

package DR::Tarantool::Space;
use Carp;
#                 name    => 'users',
#                 fields  => [
#                     qw(login password role),
#                     {
#                         name    => 'counter',
#                         type    => 'NUM'
#                     }
#                 ],
#                 indexes => {
#                     0   => 'login',
#                     1   => [ qw(login password) ],
#                 }
#             },

sub new {
    my ($class, $no, $space) = @_;
    croak 'space number must conform the regexp qr{^\d+}' unless $no ~~ /^\d+$/;
    croak "'fields' not defined in space hash"
        unless 'ARRAY' eq ref $space->{fields};
    croak "'indexes' not defined in space hash"
        unless  'HASH' eq ref $space->{indexes};

    my $name = $space->{name};
    croak 'wrong space name: ' . ($name // 'undef')
        unless $name and $name =~ /^[a-z_]\w*$/i;


    my (@fields, %fast, $default_type, $default_utf8);
    $default_utf8 = $space->{default_utf8} ? 1 : 0;
    $default_type = $space->{default_type} || 'STR';
    croak "wrong 'default_type'" unless $default_type =~ /^(?:STR|NUM|NUM64)$/;

    for (my $no = 0; $no < @{ $space->{fields} }; $no++) {
        my $f = $space->{ fields }[ $no ];

        if (ref $f eq 'HASH') {
            push @fields => {
                name    => $f->{name},
                idx     => $no,
                type    => $f->{type},
                exists($f->{utf8}) ?
                    ( utf8  => $f->{utf8} ? 1 : 0 ) :
                    ( utf8  => $default_utf8 ),
            };
        } elsif(ref $f) {
            croak 'wrong field name or description';
        } else {
            push @fields => {
                name    => $f,
                idx     => $no,
                type    => $default_type,
                utf8    => $default_utf8,
            }
        }

        my $s = $fields[ -1 ];
        croak 'unknown field type: ' . ($s->{type} // 'undef')
            unless $s->{type} and $s->{type} =~ /^(?:STR|NUM|NUM64)$/;
        delete $s->{utf8} unless $s->{type} ~~ 'STR';

        croak 'wrong field name: ' . ($s->{name} // 'undef')
            unless $s->{name} and $s->{name} =~ /^[a-z_]\w*$/i;

        $fast{ $s->{name} } = $no;
    }

    bless {
        fields          => \@fields,
        fast            => \%fast,
        name            => $name,
        default_type    => $default_type,
        default_utf8    => $default_utf8,
    } => ref($class) || $class;

}

sub name { $_[0]{name} }

sub pack_field {
    my ($self, $field, $value) = @_;
    croak q{Usage: $space->pack_field('field', $value)}
        unless @_ == 3;
    croak 'field name or number is not defined' unless defined $field;

    my $f;
    if ($field =~ /^\d+$/) {
        $f = $self->{fields}[ $field ] if $field < @{ $self->{fields} };
    } else {
        croak "field with name '$field' is not defined in this space"
            unless exists $self->{fast}{$field};
        $f = $self->{fields}[ $self->{fast}{$field} ];
    }

    my ($type, $utf8) = $f ?
        ($f->{type}, $f->{utf8}) :
        ($self->{default_type}, $self->{default_utf8})
    ;

    my $v = $value;
    utf8::encode( $v ) if utf8::is_utf8( $v );
    return $v if $type eq 'STR';
    return pack 'L<' => $v if $type eq 'NUM';
    return pack 'Q<' => $v if $type eq 'NUM64';
    croak 'Unknown field type';
}

sub unpack_field {
    my ($self, $field, $value) = @_;
    croak q{Usage: $space->pack_field('field', $value)}
        unless @_ == 3;
    croak 'field name or number is not defined' unless defined $field;

    my $f;
    if ($field =~ /^\d+$/) {
        $f = $self->{fields}[ $field ] if $field < @{ $self->{fields} };
    } else {
        croak "field with name '$field' is not defined in this space"
            unless exists $self->{fast}{$field};
        $f = $self->{fields}[ $self->{fast}{$field} ];
    }

    my ($type, $utf8) = $f ?
        ($f->{type}, $f->{utf8}) :
        ($self->{default_type}, $self->{default_utf8})
    ;

    my $v = $value;
    utf8::encode( $v ) if utf8::is_utf8( $v );
    $v = unpack 'L<' => $v if $type eq 'NUM';
    $v = unpack 'Q<' => $v if $type eq 'NUM64';
    utf8::decode( $v ) if $utf8;
    return $v;
}


sub pack_tuple {
    my ($self, $tuple) = @_;
    croak 'tuple must be ARRAYREF' unless 'ARRAY' eq ref $tuple;
    my @res;
    for (my $i = 0; $i < @$tuple; $i++) {
        push @res => $self->pack_field($i, $tuple->[ $i ]);
    }
    return \@res;
}

sub unpack_tuple {
    my ($self, $tuple) = @_;
    croak 'tuple must be ARRAYREF' unless 'ARRAY' eq ref $tuple;
    my @res;
    for (my $i = 0; $i < @$tuple; $i++) {
        push @res => $self->unpack_field($i, $tuple->[ $i ]);
    }
    return \@res;
}

package DR::Tarantool::Spaces;
use Carp;


sub new {
    my ($class, $spaces) = @_;
    croak 'spaces must be a HASHREF' unless 'HASH' eq ref $spaces;
    croak "'spaces' is empty" unless %$spaces;

    my (%spaces, %fast);
    for (keys %$spaces) {
        my $s = new DR::Tarantool::Space($_ => $spaces->{ $_ });
        $spaces{ $s->name } = $s;
        $fast{ $_ } = $s->name;
    }

    return bless {
        spaces  => \%spaces,
        fast    => \%fast,
    } => ref($class) || $class;
}

sub pack_field {
    my ($self, $space, $field, $value) = @_;
    croak q{Usage: $spaces->pack_field('space', 'field', $value)}
        unless @_ == 4;

    croak 'space name or number is not defined' unless defined $space;

    my $s;
    if ($space =~ /^\d+$/) {
        croak "space '$space' is not defined"
            unless exists $self->{fast}{$space};
        $s = $self->{spaces}{ $self->{fast}{$space} };
    } else {
        croak "space '$space' is not defined"
            unless exists $self->{spaces}{$space};
        $s = $self->{spaces}{$space};
    }
    return $s->pack_field($field => $value);
}

sub unpack_field {
    my ($self, $space, $field, $value) = @_;
    croak q{Usage: $spaces->unpack_field('space', 'field', $value)}
        unless @_ == 4;

    croak 'space name or number is not defined' unless defined $space;

    my $s;
    if ($space =~ /^\d+$/) {
        croak "space '$space' is not defined"
            unless exists $self->{fast}{$space};
        $s = $self->{spaces}{ $self->{fast}{$space} };
    } else {
        croak "space '$space' is not defined"
            unless exists $self->{spaces}{$space};
        $s = $self->{spaces}{$space};
    }
    return $s->unpack_field($field => $value);
}

sub pack_tuple {
    my ($self, $space, $tuple) = @_;
    croak q{Usage: $spaces->pack_tuple('space', $tuple)} unless @_ == 3;
    croak 'space name or number is not defined' unless defined $space;

    my $s;
    if ($space =~ /^\d+$/) {
        croak "space '$space' is not defined"
            unless exists $self->{fast}{$space};
        $s = $self->{spaces}{ $self->{fast}{$space} };
    } else {
        croak "space '$space' is not defined"
            unless exists $self->{spaces}{$space};
        $s = $self->{spaces}{$space};
    }
    return $s->pack_tuple( $tuple );
}

sub unpack_tuple {
    my ($self, $space, $tuple) = @_;
    croak q{Usage: $spaces->unpack_tuple('space', $tuple)} unless @_ == 3;

    my $s;
    if ($space =~ /^\d+$/) {
        croak "space '$space' is not defined"
            unless exists $self->{fast}{$space};
        $s = $self->{spaces}{ $self->{fast}{$space} };
    } else {
        croak "space '$space' is not defined"
            unless exists $self->{spaces}{$space};
        $s = $self->{spaces}{$space};
    }
    return $s->unpack_tuple( $tuple );
}

1;