package EnsinadorParalelo;
use Dancer2;

use CWB::CQP::More::Parallel 0.06;
use Try::Tiny;
use utf8;

our $VERSION = '0.1';
our $DEBUG = 0;

$ENV{CORPUS_REGISTRY} = config->{corpus_registry}
  if exists config->{corpus_registry};

our $utf8c =
  exists(config->{corpora_encoding}) && (config->{corpora_encoding} !~ /^utf.*8$/) ? 0 : 1;




# -----------------------------
#  Main Route: show query form
#
get '/' => sub {
    template 'index' => {
                         corpora      => config->{corpora},
                         json_corpora => to_json(config->{corpora}, { utf8 => $utf8c }),
                        };
};




# -----------------------------
#  save concordancies
#
post '/concs/save' => sub {
  my $ids = param("b");
  my $concs = session 'concs';
  my @concs = @{$concs}[@$ids];

  template 'show' => { concs => \@concs };
};



# -----------------------------
#  show concordancies
#
post '/concs' => sub {

    my $main_query = param("left");
    my $aux_query  = param("right");
    my $corpus     = param("corpus");
    my $langs      = param("languages");

    $langs ||= 0;

    # check if we have a corpus
    my $corpus_info = config->{corpora}{$corpus};
    redirect "/" unless defined $corpus_info;
    redirect "/" unless defined $main_query;

    # create the CQP object
    my $cqp = CWB::CQP::More::Parallel->new( { utf8 => $utf8c } );

    # Parse the queries
    my $expanded_main_query = guess_complex_query($main_query);
    my $expanded_aux_query  = guess_simple_query($aux_query);

    return redirect "/err" unless defined $expanded_main_query;

    # check attributes availability
    my $main_corpus = get_query_corpus($corpus_info, $langs);
    $expanded_main_query = remove_attrs_to_ignore($cqp, $main_corpus, $expanded_main_query);

    # get concordancies
    my $concs = get_concordancies($cqp,
                                  $expanded_main_query,
                                  $expanded_aux_query,
                                  $langs,
                                  $corpus_info);

    session concs => $concs;

    template 'concs' => {
                         concs => $concs,
                         query => {
                                   left  => param("left"),
                                   right => param("right"),
                                  },
                        ($DEBUG ? (mydebug => [$expanded_main_query, $concs]) : ()),
                        };
};

get '/err' => sub {
    return "ERRO NA EXPRESSAO DE PESQUISA";
};


## ----- methods --------

sub get_query_corpus {
    my ($corpus_info, $dir) = @_;

    wantarray ?
      ( $corpus_info->{cqpNames}[$dir], $corpus_info->{cqpNames}[!$dir] )
      :
      $corpus_info->{cqpNames}[$dir]
}

sub get_concordancies {
    my ($cqp, $query, $right, $dir, $corpus_info) = @_;

    my $left = join(" ", @{$query->{query}});
    $left .= " " . $query->{within} if exists $query->{within};

    my ($name, $other) = get_query_corpus($corpus_info, $dir);

    $cqp->change_corpus($corpus_info->{cqpNames}[$dir], $other);

    $cqp->set(c  => [1, $corpus_info->{context} ],
              LD => "'<b>'",
              RD => "'</b>'");

    my @lines;
    my @pos;
    try {
        my $r = $right ? ":$other $right" : "";
        $cqp->exec("A = $left $r;");

        my $size = $cqp->size("A");
        if ($size > 500) {
            $cqp->execute("reduce A to 500;");
        }

        @lines = $cqp->cat('A');
        @pos   = $cqp->dump("A");
    } catch {
        die $_;
    };

    my $annot = get_annot($cqp, $query->{attrs}, @pos);

    # Cleanup the matches, removing some unwanted markdown
    my $f = sub {
        my $line = shift;
        for ($line) {
            s/^.*?://;
            s/<p[^>]+>/<br\/>/g;
            s/<.?mwe[^>]*>//g;
            s/<reord[^>]*>//g;
            s/<br[^>]*>//g;
        }

        $line = [ split m{</?b>}, $line ] if $line =~ m/<b>/;

        return $line;
    };

    my $id = 0;

    return [ map {
        $_->[0] = $f->($_->[0]);
        $_->[1] = $f->($_->[1]);

        $_->[0][1] = [ split /\s+/, $_->[0][1] ] if ref($_->[0]) eq "ARRAY";

        +{ show  => $query->{show},
           left  => $_->[0],
           right => $_->[1],
           id    => $id++,
           anot  => shift @pos }
    } @lines ];
}


sub get_annot {
    my ($CQP, $anots, @pos)  = @_;

    my @ans;
    my $i = 0;
    for my $anot (@$anots) {
        if ($anot) {
            my $tot;
            $CQP->exec("show -word;");

            my @npos = map {
                $_ = [ @$_ ]; # clone
                $_->[0] = $_->[1] = $_->[0] + $i;
                $_->[2] = -1;  # in any case...
                $_
            } @pos;

            for my $a (@$anot) {
                $CQP->exec("show +$a;");
                $CQP->exec("set c 0;");
                $CQP->undump("B" => @npos);

                my @tans = map { s/^.*\[%\s*//; s/\s*%\]\s*$//; $_ } $CQP->exec("cat B;");
                $CQP->exec("show -$a;");

                my $j = 0;
                for (@tans) {
                    push @{$ans[$j][$i]} => $_;
                    ++$j;
                }
            }
        }
        $i++;
    }

    for my $a (@ans) {
        $a = join(", ", map { join(" ", $_ ? @$_ : () )  }  @$a);
        $a =~ s/,\s+,/,/g;
        $a =~ s/^\s*,\s*//;
        $a =~ s/\s*,\s*$//;
    }

    return \@ans;
}


sub guess_simple_query {
    my $query = shift;
    return "" unless $query !~ /^\s*$/;

    $query =~ s/^\s+//;
    $query =~ s/\s+$//;

    ## query is just words?
    $query = join(" ", map { "[word=\"$_\"]" } split(/\s+/, $query)) if $query =~ /^[ [:alpha:]]+$/;

    $query = "[word=\"$query\"]" if $query =~ /^[\|[:alpha:]]+$/;

    $query = _expand_query($query);
    my $within = "";
    $within = $1 if $query =~ s/( within .*$)//;

    return $query;
}


sub guess_complex_query {
    my $query = shift;
    return "" unless $query !~ /^\s*$/;

    $query =~ s/^\s+//;
    $query =~ s/\s+$//;

    ## query is just words?
    $query = join(" ", map { "[word=\"$_\"]" } split(/\s+/, $query)) if $query =~ /^[ [:alpha:]]+$/;

    $query = "[word=\"$query\"]" if $query =~ /^[\|[:alpha:]]+$/;

    $query = _expand_query($query); # trata withins

    my $within = "";
    $within = $1 if $query =~ s/( within .*$)//;

    my $res;

    ### PARSER

    ## Analisar o pedido e retirar os detalhes específicos à notação
    ## do ensinador.
    while ($query =~ s{^
                       (?:
                           ( <[^>]+> )
                       |   (?: "([^"]+)" )
                       |
                           (?:
                               ( (?: [a-z]+:)? \[  (?: [^\]"]+ | " [^"]+ " )*  \] )
                               ( (?: ~ | (?: \. [a-zA-Z_]* )+)   |  (?:[*+]|\{\d+(?:,\d+)?\})?  |  )
                           )
                       )
                       \s*
                  }{}gx) {

        ## 1, 2, e 3 fazem parte da sintaxe CWB
        ## 4 é a anotação (ponto seguido do atributo, ou atributo omisso)
        ##   ou símbolos de repetição (kleene et al)
        my ($q, $attr) = ($1 || $2 || $3, $4);
        if ($q =~ /^</) {
            push @{$res->{query}} => $q;
            push @{$res->{attrs}} => undef;
            push @{$res->{show}}  => 1;
        } elsif ($q !~ /^(?:[a-z]+:)?\[/) {
            push @{$res->{query}} => qq{[word="$q"]};
            push @{$res->{attrs}} => undef;
            push @{$res->{show}}  => 1;
        } else {
            if ($attr =~ /[+*{]/) {
                $q = $q . $attr;
                $attr = "";
                push @{$res->{show}}  => -1;
            } elsif ($attr =~ s/^~//) {
                push @{$res->{show}}  => 0;
            } else {
                push @{$res->{show}}  => 1;
            }
            $attr =~ s/^\.//;
            push @{$res->{query}} => $q;
            push @{$res->{attrs}} => $attr ? [ split /\./ => $attr ] : undef;
        }
    }

    $query =~ s/^\s*$//;
    if ($query) {
        return undef;
    } else {
        $res->{within} = $within if $within;
        return $res;
    }
}


# Gets all the s/p attributes in the corpus
sub attributes {
    my ($cqp, $cp, %ops) = @_;
    $cqp->exec(uc $cp);

    my @attributes = $cqp->exec("show cd;");
    my $attributes;
    for (@attributes) {
        my @line = split /\t/;
        if ($ops{hash_form}) {
            $attributes->{$line[1]} = $1 if $line[0] =~ /([ps])-Att/;
        } else {
            push @{$attributes->{p}}, $line[1] if $line[0] =~ /p-Att/;
            push @{$attributes->{s}}, $line[1] if $line[0] =~ /s-Att/;
        }
    }
    return $attributes;
}

sub remove_attrs_to_ignore {
    my ($cqp, $corpus, $query) = @_;

    my %ignoring_attributes;
    # check if somebody asked for extra non-existing attributes
    my $corpus_attributes = attributes($cqp, $corpus, hash_form => 1);

    for my $atlist (@{$query->{attrs}}) {
        next unless $atlist;
        for my $at (@$atlist) {
            $ignoring_attributes{$at}++ unless exists $corpus_attributes->{$at};
        }
        $atlist = [ grep { !exists($ignoring_attributes{$_}) } @$atlist ];
    }
    return $query;
}

sub _expand_query {
    my $query = shift;
    for ($query) {  # nao e' array, mas o codigo fica mais limpo...
        s/within\s+([0-9]+\s)*parte\s*/within 100/g;
        s/within\s+([0-9]+\s)*texto\s*/within 100/g;
        s/within\s+([0-9]+\s)*obra\s*/within 100/g;

        s/within\s+([0-9]+\s)*capitulo\s*/within 100/g;
        s/within\s+([0-9]+\s)*art\s*/within 100/g;
        s/within\s+[0-9]+\s+ext\s*/within ext/g;
        s/within\s+[0-9]+\s+p\s*/within p/g;
        s/within\s+[3-9]+\s+s\s*/within 3 s/g;
        s/within\s+[0-9][0-9]+\ss\s*/within 3 s/g;

        s/within\s+([0-9]+\s)*fala\s*/within fala/g;
        s/within\s+[3-9]+\s+u\s*/within 3 u/g;
        s/within\s+[0-9][0-9]+\su\s*/within 3 u/g;

        s/within\s+[3-9][0-9][0-9]+\s*$/within 100/g;
        s/within\s+[3-9][0-9][0-9]+\s*\;/within 100\;/g;
        s/within\s+[0-9][0-9][0-9][0-9]+\s*$/within 100/g;
        s/within\s+[0-9][0-9][0-9][0-9]+\s*\;/within 100\;/g;

        #s/(^| )"(\S+)"( |$)/${1}[word="$2"]$3/g;
    }
    return $query;
}

true;
