package Speech::Recognition::Boilerplate;
use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

sub import {
    require feature;
    feature->import(':5.34');
    require strict;
    strict->import();
    feature->import('signatures');
    warnings->unimport('experimental::signatures');
    warnings->import();
}

1;
