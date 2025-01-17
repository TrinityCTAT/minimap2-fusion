#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long qw(:config no_ignore_case bundling pass_through);
use List::Util qw (min max);
use FindBin;
use lib ("$FindBin::Bin/../PerlLib");
use Set::IntervalTree;

my $min_per_id = 80;


my $usage = <<__EOUSAGE__;

#####################################################################
#
# Required:
#
#  --align_gff3 <string>        gff3 alignment output
#
#  --annot_gtf <string>        transcript structures in gtf file format.
#
#  --min_per_id <float>        minimum percent identity (default: $min_per_id)
#
#
#  --debug|D                   debug mode, extra verbose
#
######################################################################


__EOUSAGE__

    ;


my $help_flag;
my $align_gff3_file;
my $annot_gtf_file;

my $DEBUG = 0;

&GetOptions ( 'h' => \$help_flag,
              'align_gff3=s' => \$align_gff3_file,
              'annot_gtf=s' => \$annot_gtf_file,
              'min_per_id=f' => \$min_per_id,
              'debug|D' => \$DEBUG,
              );


if ($help_flag) {
    die $usage;
}

unless ($align_gff3_file && $annot_gtf_file && defined($min_per_id) && $min_per_id > 1) {
    die $usage;
}


my %genes;
my %interval_trees;
my $error_counter = 0;

main: {

    ########################
    ## Parsing reference GTF 
    ########################
    
    my %chr_to_gene_coords = &parse_ref_annotations($annot_gtf_file);
    
    #########################################
    ## Build interval tree for exons of genes
    #########################################
    
    print STDERR "-building interval tree for fast searching of gene overlaps\n";
    ## Build interval trees

    &build_ref_annot_interval_trees(%chr_to_gene_coords);

    ######################################
    ## Parse minimap2 alignments for reads
    ## and
    ## Map candidate fusion transcripts to gene annotations
    #######################################################
    

    print STDERR "-mapping candidate fusion transcripts to gene annotations.\n";
    ## header
    print join("\t", "#transcript", "num_alignments", "align_descr(s)", "[chim_annot_mapping]") . "\n";

    
    my %target_to_aligns;
    my $prev_target = "";
    
    print STDERR "-loading alignment data\n";
    open (my $fh, $align_gff3_file) or die $!;
    while (<$fh>) {
        if (/^\#/) { next; }
        unless (/\w/) { next; }

        chomp;
        my ($chr, $filename, $type, $lend, $rend, $per_id, $orient, $dot, $info) = split(/\t/);
        
        my %info_hash;
        foreach my $keyval (split(/;/, $info)) {
            my ($key, $val) = split(/=/, $keyval);
            $info_hash{$key} = $val;
        }

        my $alignment_ID = $info_hash{ID};
        
        my ($target, $range_lend, $range_rend) = split(/\s+/, $info_hash{Target});

        if ($target ne $prev_target && %target_to_aligns) {
            if ($DEBUG) { print "Evaluating $target\n";}
            &evaluate_target_alignments(%target_to_aligns);
            %target_to_aligns = (); # reinit
        }
        $prev_target = $target;
        
        push (@{$target_to_aligns{$target}->{$alignment_ID}}, { chr => $chr,
                                                                lend => $lend,
                                                                rend => $rend,
                                                                orient => $orient,
                                                                per_id => $per_id,
                                                                
                                                                range_lend => $range_lend,
                                                                range_rend => $range_rend,
                                                            });
        
    }
    close $fh;


    # get last one
    if (%target_to_aligns) {
        &evaluate_target_alignments(%target_to_aligns);
    }
    
    
    if ($error_counter) {
        print STDERR "*** $error_counter alignment errors were identified.\n\n";
    }

    print STDERR "-done";
    
    exit(0);
}





sub evaluate_target_alignments {
    my %target_to_aligns = @_;


    if ($DEBUG) {
        print Dumper(\%target_to_aligns);
    }
    
    foreach my $target (keys %target_to_aligns) {
     

        # examine all the alignments for a given transcript.  A fusion transcript will
        # have at least 2 alignments reported in chimera-alignment mode.
        # For each ordered pair of alignment segments (A,B), map each 
        # to gene annotations and identify candidate fusion gene pairs.
        

        ## create spans
        my @span_ids = keys %{$target_to_aligns{$target}};
        if (scalar @span_ids < 2) {
            if ($DEBUG) {
                print STDERR "-skipping $target as non chimeric candidate\n";
            }
            next;

        } # only want candidate chimeras
        
        my @spans;
        foreach my $span_id (@span_ids) {
            #print STDERR "// $target  $span_id\n";
            my $exon_hits_aref = $target_to_aligns{$target}->{$span_id};
            
            eval {
                my $span_struct = &convert_to_span($exon_hits_aref);
                if ($span_struct->{per_id} >= $min_per_id) {
                    push (@spans, $span_struct);
                }
            };
            if ($@) {
                print STDERR $@;
                $error_counter += 1;
            }
            
        }
        

        my $outline_text = "$target";

        my $num_aligns = scalar @spans;
        $outline_text .= "\t$num_aligns";

        my $prev_align;

        my @chim_align_descrs;
        my @at_exon_junctions;
        
        
        @spans = sort {$a->{range_lend}<=>$b->{range_lend}} @spans; # order spans according to transcript coordinates


        if ($DEBUG) {
            print STDERR "Target $target has spans: " . Dumper(\@spans);
        }
        
        my @fusion_preds;


        foreach my $align (@spans) {
        
            my $chr = $align->{chr};
                                
            my $lend = $align->{lend};
            my $rend = $align->{rend};

            my $range_lend = $align->{range_lend};
            my $range_rend = $align->{range_rend};
            my $orient = $align->{orient};
            my $per_id = $align->{per_id};
            

            my $align_text = "[$chr:($range_lend-$range_rend)$lend-$rend ($orient) $per_id\%]";
            $align->{align_text} = $align_text;

            
            if ($prev_align) {
                
                my ($left_align, $right_align) = ($prev_align, $align);
                
                my @left_possibilities = &map_to_annotated_exon_junctions($left_align, 'left');

                my @right_possibilities = &map_to_annotated_exon_junctions($right_align, 'right');

                if ($DEBUG) {
                    print STDERR "Annot mappings: \ttarget $target, left possibilities: " . Dumper(\@left_possibilities) . " and right possibilities: " . Dumper(\@right_possibilities);
                }
                
                
                foreach my $left_possibility (@left_possibilities) {

                    foreach my $right_possibility (@right_possibilities) {
                        
                        my ($left_entry, $right_entry) = ($left_possibility, $right_possibility);
                        

                        if ($left_entry->{gene_id} eq $right_entry->{gene_id}) { next; } # no selfies

                        unless ($left_entry->{sense_or_antisense} eq $right_entry->{sense_or_antisense}) {
                            next;
                        }
                        
                        if ($left_entry->{sense_or_antisense} eq 'antisense') {
                            # swap em
                            ($left_entry, $right_entry) = ($right_entry, $left_entry);
                        }
                    
                        

                        my @at_exon_junctions = ($left_entry->{gene_id}, $left_entry->{delta}, $left_entry->{trans_brkpt}, $left_entry->{chr} . ":" . $left_entry->{pt_align}, 
                                                 $right_entry->{gene_id}, $right_entry->{delta}, $right_entry->{trans_brkpt}, $right_entry->{chr} . ":" . $right_entry->{pt_align},
                                                 join("--", $left_entry->{gene_id}, $right_entry->{gene_id}));
                        
                        my @chim_align_descrs = ($left_entry->{alignment}->{align_text}, $right_entry->{alignment}->{align_text});
                        
                        
                        
                        my $report_text = $outline_text . "\t" . join(";", @chim_align_descrs) . "\t" . join(";", @at_exon_junctions) . "\n";
                        
                        
                        my $fusion_pred = { left_entry => $left_entry,
                                            right_entry => $right_entry,
                                            delta_sum => $left_entry->{delta} + $right_entry->{delta},
                                            report_text => $report_text,
                        };
                        
                        push (@fusion_preds, $fusion_pred);
                                            
                    }
                }
            }
            
            $prev_align = $align;
            
        } # end for each align


        ## Report a fusion
        if (@fusion_preds) {
            @fusion_preds = sort {$a->{delta_sum}<=>$b->{delta_sum}} @fusion_preds;
            my $min_delta_sum = $fusion_preds[0]->{delta_sum};
            while (@fusion_preds) {
                my $pred = shift @fusion_preds;
                if ($pred->{delta_sum} == $min_delta_sum) {
                    print $pred->{report_text};
                }
                else {
                    last;
                }
            }
        }
        

    } # end for each target


    return;
}



sub parse_ref_annotations {
    my ($annot_gtf_file) = @_;


    print STDERR "-parsing $annot_gtf_file\n";
    my $fh;
    if ($annot_gtf_file =~ /\.gz$/) {
        open ($fh, "gunzip -c $annot_gtf_file | ") or die "Error, cannot open file gunzip -c $annot_gtf_file";
    }
    else {
        open ($fh, $annot_gtf_file) or die "Error, cannot open file $annot_gtf_file";
    }


    my %chr_to_gene_coords;
    
    while (<$fh>) {
        chomp;
        unless (/\w/) { next; }
        if (/^\#/) { next; }
        s/^>//;
        my @x = split(/\t/);
        
        unless ($x[2] eq "exon") { next; }
        
        my $info = $x[8];
        $info =~ /gene_id \"([^\"]+)/ or die "Error, cannot extract gene_id from $_ [specifically from: $info]";
        my $gene_id = $1 or die "Error, no gene_id from $_";
        
        if ($info =~ /gene_name \"([^\"]+)/) {
            # use gene name instead
            $gene_id = $1;
        }
        
        $info =~ /transcript_id \"([^\"]+)/ or die "Error, cannot extract transcript_id from $_";
        my $transcript_id = $1 or die "Error, no trans id from $_";
        
        my ($lend, $rend) = ($x[3], $x[4]);
        my $chr = $x[0];
        my $orient = $x[6];
        
        
        push (@{$genes{$chr}->{$gene_id}->{$transcript_id}}, { 
            
            gene => $gene_id,
            transcript => $transcript_id,
            chr => $chr,
            lend => $lend,
            rend => $rend,
            orient => $orient,
              }
            );
        
        push (@{$chr_to_gene_coords{$chr}->{$gene_id}}, $lend, $rend);
        
    }
    close $fh;

    return(%chr_to_gene_coords);
}





####
sub build_ref_annot_interval_trees {
    my %chr_to_gene_coords = @_;
    
    foreach my $chr (keys %chr_to_gene_coords) {

        my $i_tree = $interval_trees{$chr} = Set::IntervalTree->new;
        
        foreach my $gene_id (keys %{$chr_to_gene_coords{$chr}}) {
            
            my @coords = sort {$a<=>$b} @{$chr_to_gene_coords{$chr}->{$gene_id}};
            my $lend = shift @coords;
            my $rend = pop @coords;

            $i_tree->insert($gene_id, $lend, $rend);
        }
    }

    return;
}


####
sub map_to_annotated_exon_junctions {
    my ($align_struct, $left_or_right) = @_;
    
    my $chr = $align_struct->{chr};
    my $align_lend = $align_struct->{lend};
    my $align_rend = $align_struct->{rend};
    my $align_orient = $align_struct->{orient};
    
    my ($align_end5, $align_end3) = ($align_orient eq '+') ? ($align_lend, $align_rend) : ($align_rend, $align_lend);
    
    my ($range_lend, $range_rend) = ($align_struct->{range_lend}, $align_struct->{range_rend});
    
    my %genome_to_trans_coord_mapping = ( $align_end5 => $range_lend,
                                          $align_end3 => $range_rend );
    
    # two options, depending on sense or antisense alignment (antisense orientation just an artifiact of DS trans assembly)
    
    #          L                               R
    #        ------> gt...................ag -------->              
    #
    #   |=================>              |==================>
    #         gene A                            gene B
    #
    #        <------ ......................<---------
    #           R                               L
    # 
    #  if left:
    #      can be donor matching sense of geneA
    #      can be acceptor matching antisense of geneB
    #  if right:
    #      can be acceptor for sense geneB
    #      can be donor matching antisesnse of geneA
    #
    
    my @hits;

    foreach my $gene_id (&get_overlapping_genes($chr, $align_lend, $align_rend)) {
        
        foreach my $transcript_id (keys %{$genes{$chr}->{$gene_id}}) {
            
            my @exons = @{$genes{$chr}->{$gene_id}->{$transcript_id}};
            
            @exons = sort {$a->{lend}<=>$b->{lend}} @exons;

            my $trans_lend = $exons[0]->{lend};
            my $trans_rend = $exons[$#exons]->{rend};
            
            unless ($align_lend < $trans_rend && $trans_rend > $align_lend) { 
                # no overlap
                next;
            }
            
            ## exclude first and last exons, only looking at internal boundaries
            $exons[0]->{terminal} = 1;
            $exons[$#exons]->{terminal} = 1;
            
            my $num_exons = scalar(@exons);
            my $counter= 0;
            foreach my $exon (@exons) {
                $counter++;
                $exon->{exon_num} = "$counter/$num_exons";
            }
            
                        
            foreach my $exon (@exons) {
                
                my $exon_lend = $exon->{lend};
                my $exon_rend = $exon->{rend};
                my $exon_orient = $exon->{orient};
                
                my ($exon_end5, $exon_end3) = ($exon_orient eq '+') ? ($exon_lend, $exon_rend) : ($exon_rend, $exon_lend);
                

                if ($exon_lend < $align_rend && $exon_rend > $align_lend ) {
                    # annotated exon overlaps transcript
                    
                    my $sense_or_antisense;
                    my $exon_coord;
                    my $align_coord;
                    
                    # sense alignment matching
                    if ($exon_orient eq $align_orient) {
                        
                        $sense_or_antisense = 'sense';
                        
                        if ($left_or_right eq 'left') {
                            # examine donor sites
                            $exon_coord = $exon_end3;
                            $align_coord = $align_end3;
                        }
                        elsif ($left_or_right eq 'right') {
                            # examine acceptor sites
                            $exon_coord = $exon_end5;
                            $align_coord = $align_end5;
                        }
                    }
                    else {
                        # antisense orientation to gene
                        
                        $sense_or_antisense = 'antisense';
                        
                        if ($left_or_right eq 'left') {
                            # examine donor sites
                            $align_coord = $align_end3;
                            $exon_coord = $exon_end5;
                        }
                        elsif ($left_or_right eq 'right') {
                            $align_coord = $align_end5;
                            $exon_coord = $exon_end3;
                        }    
                    }
                    
                    my $delta = abs($align_coord - $exon_coord);
                    
                    
                    push (@hits, { delta => $delta,
                                   exon => $exon,
                                   
                                   gene_id => $exon->{gene},
                                   
                                   # below for debugging
                                   pt_align => $align_coord,
                                   pt_exon => $exon_coord,
                                   sense_or_antisense => $sense_or_antisense,
                                   
                                   # align struct
                                   alignment => $align_struct,
                                   chr => $chr,

                                   trans_brkpt => $genome_to_trans_coord_mapping{$align_coord},
                                   
                               });
                    
                }
            }
            
        }
    }

    
    my @hits_ret;
    
    if (@hits) {

        #use Data::Dumper;  print Dumper(\@hits); print Dumper($align_struct);
        
        @hits = sort {$a->{delta}<=>$b->{delta}} @hits;
        
        #use Data::Dumper;
        #print STDERR Dumper(\@hits);
        
        # only best per gene
        my %seen;
        
        foreach my $hit (@hits) {
            my $gene_id = $hit->{gene_id};
            if (! $seen{$gene_id}) {
                push (@hits_ret, $hit);
                $seen{$gene_id} = 1;
            }
        }
        
    }
    
    return(@hits_ret);
    
}


####
sub convert_to_span {
    my ($exons_aref) = @_;

    my @chr_coords;
    my @span_coords;
    
    my $orient;
    my $chr;
    
    my $sum_per_id = 0;
    my $sum_len = 0;

    foreach my $exon (@$exons_aref) {
        
        # chr_coords
        push (@chr_coords, $exon->{lend});
        push (@chr_coords, $exon->{rend});
       
        # transcript_coords
        push (@span_coords, $exon->{range_lend});
        push (@span_coords, $exon->{range_rend});

        my $len = abs($exon->{rend} - $exon->{lend} + 1);
        $sum_len += $len;
        $sum_per_id += $len * $exon->{per_id};
        

        my $exon_chr = $exon->{chr};
        if ($chr && $exon_chr ne $chr) {
            die "inconsistent ($chr) chr assignments: " . Dumper($exons_aref);
        }
        else {
            $chr = $exon_chr;
        }
        
        my $exon_orient = $exon->{orient};
        if ($orient && $exon_orient ne $orient) {
            die "inconsistent exon orient: " . Dumper($exon) . " all exons: " . Dumper($exons_aref);;
        }
        else {
            $orient = $exon_orient;
        }
    }
    
    @chr_coords = sort {$a<=>$b} @chr_coords;
    @span_coords = sort {$a<=>$b} @span_coords;
    
    my $chr_coords_lend = $chr_coords[0];
    my $chr_coords_rend = $chr_coords[$#chr_coords];
    
    my $span_coords_lend = $span_coords[0];
    my $span_coords_rend = $span_coords[$#span_coords];
    

    my $per_id = $sum_per_id / $sum_len;

    my $span_struct = { lend => $chr_coords_lend,
                        rend => $chr_coords_rend,
                        orient => $orient,
                        chr => $chr,

                        range_lend => $span_coords_lend,
                        range_rend => $span_coords_rend,

                        exons => $exons_aref,
                    
                        per_id => sprintf("%.2f", $per_id),
                        
                    };

    return($span_struct);
}

####
sub get_overlapping_genes {
    my ($chr, $lend, $rend) = @_;
    
    if ($lend == $rend) {
        ## let's not trust this single point.
        return();
    }
    

    my $interval_tree = $interval_trees{$chr};

    unless (ref $interval_tree) {
        # no genes on that chr?
        return();
    }

    my $overlaps = $interval_tree->fetch($lend, $rend);

    return(@$overlaps);
}


        
    
