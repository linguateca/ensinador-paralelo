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

    my $g = guess_complex_query($main_query);

    $main_query = join(" ", @{$g->{query}});

    my $concs = get_concordancies($main_query, $aux_query, $langs, $corpus);

    session concs => $concs;

    template 'concs' => {
                         concs => $concs,
                         query => {
                                   left  => param("left"),
                                   right => param("right"),
                                  },
                        ($DEBUG ? (mydebug => $g) : ()),
                        };
};


sub get_concordancies {
    my ($left, $right, $dir, $corpus) = @_;

    my $corpus_info = config->{corpora}{$corpus};
    redirect "/" unless defined $corpus_info;
    redirect "/" unless defined $left;


    my $cqp = CWB::CQP::More::Parallel->new( { utf8 => $utf8c } );

    my $name = $corpus_info->{cqpNames}[$dir];

    $cqp->change_corpus($corpus_info->{cqpNames}[$dir]);
    my $other = $corpus_info->{cqpNames}[!$dir];

    $cqp->set(c  => [1, config->{corpora}{$corpus}{context} ],
              LD => "'<b>'",
              RD => "'</b>'");

    my @lines;
    try {
        my $r = $right ? ":$other $right" : "";
        $cqp->exec("A = $left $r;");
        @lines = $cqp->cat('A');
    } catch {
        die $_;
    };

    # Cleanup the matches, removing some unwanted markdown
    my $f = sub {
        my $line = shift;
        for ($line) {
            s/^.*?://;
            s/<p[^>]+>/<br\/>/g;
            s/<.?mwe[^>]*>//g;
        }

        $line = [ split m{</?b>}, $line ] if $line =~ m/<b>/;

        return $line;
    };

    my $id = 0;
    return [ map {
        $_->[0] = $f->($_->[0]);
        $_->[1] = $f->($_->[1]);
        +{ left => $_->[0], right => $_->[1], id => $id++ }
    } @lines ];
}


sub guess_complex_query {
    my $query = shift;
    return "" unless $query !~ /^\s*$/;

    $query =~ s/^\s+//;
    $query =~ s/\s+$//;

    ## query is just words?
    $query = join(" ", map { "[word=\"$_\"]" } split(/\s+/, $query)) if $query =~ /^[ [:alpha:]]+$/;



    $query = "[word=\"$query\"]" if $query =~ /^[\|[:alpha:]]+$/;

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


true;
