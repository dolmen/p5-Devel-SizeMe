#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

use DBI qw(looks_like_number);
use DBD::SQLite;
use JSON::XS;

use Getopt::Long;

GetOptions(
    'text!' => \my $opt_text,
    'dot=s' => \my $opt_dot,
    'db=s'  => \my $opt_db,
    'verbose|v!' => \my $opt_verbose,
    'debug|d!' => \my $opt_debug,
    'showid!' => \my $opt_showid,
) or exit 1;

my $j = JSON::XS->new->ascii->pretty(0);

my ($dbh, $node_ins_sth);
if ($opt_db) {
    $dbh = DBI->connect("dbi:SQLite:dbname=$opt_db","","", {
        RaiseError => 1, PrintError => 0, AutoCommit => 0
    });
    $dbh->do("PRAGMA synchronous = OFF");
    $dbh->do("DROP TABLE IF EXISTS node");
    $dbh->do(q{
        CREATE TABLE node (
            id integer primary key,
            name text,
            title text,
            type integer,
            depth integer,
            parent_id integer,

            self_size integer,
            kids_size integer,
            kids_node_count integer,
            child_ids text,
            attr_json text,
            leaves_json text
        )
    });
    $node_ins_sth = $dbh->prepare(q{
        INSERT INTO node VALUES (?,?,?,?,?,?,  ?,?,?,?,?,?)
    });
}

my @stack;
my %seqn2node;

use HTML::Entities qw(encode_entities);;
my $dotnode = sub {
    my $name = encode_entities(shift);
    $name =~ s/"/\\"/g;
    return '"'.$name.'"';
};


my $dot_fh;
if ($opt_dot) {
    open $dot_fh, ">$opt_dot";
    print $dot_fh "digraph {\n"; # }
    print $dot_fh "graph [overlap=false]\n"; # target="???", URL="???"
}

sub fmt_size {
    my $size = shift;
    my $kb = $size / 1024;
    return $size if $kb < 5;
    return sprintf "%.1fKb", $kb if $kb < 1000;
    return sprintf "%.1fMb", $kb/1024;
}


sub enter_node {
    my $x = shift;
    if ($opt_dot) {
        #printf $fh qq{\tn%d [ %s ]\n}, $x->{id}, $dotnode->($x->{name});
        #print qq({ "id": "$x->{id}", "name": "$x->{name}", "depth":$x->{depth}, "children":[ \n);
    }
    return;
}

sub leave_node {
    my $x = shift;
    delete $seqn2node{$x->{id}};

    my $self_size = 0; $self_size += $_  for values %{$x->{leaves}};
    $x->{self_size} = $self_size;

    my $parent = $stack[-1];
    if ($parent) {
        # link to parent
        $x->{parent_id} = $parent->{id};
        # accumulate into parent
        $parent->{kids_node_count} += 1 + ($x->{kids_node_count}||0);
        $parent->{kids_size} += $self_size + $x->{kids_size};
        push @{$parent->{child_id}}, $x->{id};
    }
    # output
    # ...
    if ($opt_dot) {
        printf "// n%d parent=%s(type=%s)\n", $x->{id},
                $parent ? $parent->{id} : "",
                $parent ? $parent->{type} : ""
            if 0;
        if ($x->{type} != 2) {
            my $name = $x->{title} ? "\"$x->{title}\" $x->{name}" : $x->{name};

            if ($x->{kids_size}) {
                $name .= sprintf " %s+%s=%s", fmt_size($x->{self_size}), fmt_size($x->{kids_size}), fmt_size($x->{self_size}+$x->{kids_size});
            }
            else {
                $name .= sprintf " +%s", fmt_size($x->{self_size});
            }
            $name .= " $x->{id}" if $opt_showid;

            my @node_attr = (
                sprintf("label=%s", $dotnode->($name)),
                "id=$x->{id}",
            );
            my @link_attr;
            #if ($x->{name} eq 'hek') { push @node_attr, "shape=point"; push @node_attr, "labelfontsize=6"; }
            if ($parent) { # probably a link
                my $parent_id = $parent->{id};
                my @link_attr = ("id=$parent_id");
                if ($parent->{type} == 2) { # link
                    (my $link_name = $parent->{name}) =~ s/->$//;
                    push @link_attr, (sprintf "label=%s", $dotnode->($link_name));
                    $parent_id = ($stack[-2]||die "panic")->{id};
                }
                printf $dot_fh qq{n%d -> n%d [%s];\n},
                    $parent_id, $x->{id}, join(",", @link_attr);
            }
            printf $dot_fh qq{n%d [ %s ];\n}, $x->{id}, join(",", @node_attr);
        }

    }
    if ($dbh) {
        my $attr_json = $j->encode($x->{attr});
        my $leaves_json = $j->encode($x->{leaves});
        $node_ins_sth->execute(
            $x->{id}, $x->{name}, $x->{title}, $x->{type}, $x->{depth}, $x->{parent_id},
            $x->{self_size}, $x->{kids_size}, $x->{kids_node_count},
            $x->{child_id} ? join(",", @{$x->{child_id}}) : undef,
            $attr_json, $leaves_json,
        );
        # XXX attribs
    }
    return;
}

my $indent = ":   ";

while (<>) {
    chomp;
    my ($type, $id, $val, $name, $extra) = split / /, $_, 5;
    if ($type =~ s/^-//) {     # Node type ($val is depth)
        printf "%s%s %s [#%d @%d]\n", $indent x $val, $name, $extra||'', $id, $val
            if $opt_text;
        while ($val < @stack) {
            leave_node(my $x = pop @stack);
            warn "N $id d$val ends $x->{id} d$x->{depth}: size $x->{self_size}+$x->{kids_size}\n"
                if $opt_verbose;
        }
        die "panic: stack already has item at depth $val"
            if $stack[$val];
        my $node = $stack[$val] = { id => $id, type => $type, name => $name, extra => $extra, attr => {}, leaves => {}, depth => $val, self_size=>0, kids_size=>0 };
        enter_node($node);
        $seqn2node{$id} = $node;
    }
    elsif ($type eq "L") {  # Leaf name and memory size
        my $node = $seqn2node{$id} || die;
        $node->{leaves}{$name} += $val;
        printf "%s+%d %s\n", $indent x ($node->{depth}+1), $val, $name
            if $opt_text;
    }
    elsif (looks_like_number($type)) {  # Attribute type, name and value
        my $node = $seqn2node{$id} || die;
        my $attr = $node->{attr} || die;
        printf "%s~%s %d [t%d]\n", $indent x ($node->{depth}+1), $name, $val, $type
            if $opt_text;
        if ($type == 1 or $type == 5) { # NPattr_NAME
            warn "Node $id already has attribute $type:$name (value $attr->{$type}{$name})\n"
                if exists $attr->{$type}{$name};
            $attr->{$type}{$name} = $val || $id;
            $node->{title} = $name if $type == 1 and !$val;
        }
        elsif (2 <= $type and $type <= 4) { # NPattr_PAD*
            warn "Node $id already has attribute $type:$name (value $attr->{$type}[$val])\n"
                if defined $attr->{$type}[$val];
            $attr->{$type}[$val] = $name;
        }
        else {
            warn "Invalid attribute type '$type' on line $. ($_)";
        }
    }
    else {
        warn "Invalid type '$type' on line $. ($_)";
        next;
    }
    $dbh->commit if $dbh and $id % 10_000 == 0;
}

my $top = $stack[0]; # grab top node before we pop all the nodes
leave_node(pop @stack) while @stack;
warn "EOF ends $top->{id} d$top->{depth}: size $top->{self_size}+$top->{kids_size}\n"
    if $opt_verbose;
warn Dumper($top) if $opt_verbose;

if ($dot_fh) {
    print $dot_fh "}\n";
    close $dot_fh;
    system("open -a Graphviz $opt_dot");
}

$dbh->commit if $dbh;

use Data::Dumper;
warn Dumper(\%seqn2node) if %seqn2node; # should be empty

=for
SV(PVAV) fill=1/1       [#1 @0] 
:   +64 sv =64 
:   +16 av_max =80 
:   AVelem->        [#2 @1] 
:   :   SV(RV)      [#3 @2] 
:   :   :   +24 sv =104 
:   :   :   RV->        [#4 @3] 
:   :   :   :   SV(PVAV) fill=-1/-1     [#5 @4] 
:   :   :   :   :   +64 sv =168 
:   AVelem->        [#6 @1] 
:   :   SV(IV)      [#7 @2] 
:   :   :   +24 sv =192 
192 at -e line 1.
=cut
__DATA__
N 1 0 SV(PVAV) fill=1/1
L 1 64 sv
L 1 16 av_max
N 2 1 AVelem->
N 3 2 SV(RV)
L 3 24 sv
N 4 3 RV->
N 5 4 SV(PVAV) fill=-1/-1
L 5 64 sv
N 6 1 AVelem->
N 7 2 SV(IV)
L 7 24 sv
