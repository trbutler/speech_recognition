package Speech::Recognition::AudioFile;

use v5.36;
use Carp       qw(croak);
use File::Temp qw(tempfile);

our $VERSION = '0.01';

=head1 NAME

Speech::Recognition::AudioFile - Audio source backed by a WAV, AIFF, or FLAC file

=head1 SYNOPSIS

    use Speech::Recognition::AudioFile;
    use Speech::Recognition::Recognizer;

    my $r = Speech::Recognition::Recognizer->new;

    # Using the with() helper (recommended — ensures the file is closed)
    my $audio;
    Speech::Recognition::AudioFile->new(filename => 'speech.wav')->with(sub ($src) {
        $audio = $r->record($src);
    });

    # Or manage open/close manually
    my $source = Speech::Recognition::AudioFile->new(filename => 'speech.wav');
    $source->open;
    my $audio2 = $r->record($source);
    $source->close;

=head1 DESCRIPTION

Provides an audio-source interface over a file on disk.  Supported formats are:

=over 4

=item * WAV (PCM only)

=item * AIFF / AIFF-C

=item * Native FLAC (decoded via the C<flac> command-line tool)

=back

Stereo files are automatically downmixed to mono.

=cut

# ---------------------------------------------------------------------------
# Inner stream class
# ---------------------------------------------------------------------------

package Speech::Recognition::AudioFile::Stream;

use v5.36;

sub new ( $class, $pcm_data, $sample_width ) {
    return bless {
        _data  => $pcm_data,
        _pos   => 0,
        _width => $sample_width,
    }, $class;
}

# Read $nsamples samples and return the corresponding bytes.
sub read ( $self, $nsamples ) {
    my $nbytes = $nsamples * $self->{_width};
    my $avail  = length( $self->{_data} ) - $self->{_pos};
    return '' if $avail <= 0;
    $nbytes = $avail if $nbytes > $avail;
    my $chunk = substr( $self->{_data}, $self->{_pos}, $nbytes );
    $self->{_pos} += length($chunk);
    return $chunk;
}

sub close ($self) {
    $self->{_data} = '';
    $self->{_pos}  = 0;
}

# ---------------------------------------------------------------------------
# AudioFile
# ---------------------------------------------------------------------------

package Speech::Recognition::AudioFile;

use v5.36;
use Carp       qw(croak);
use File::Temp qw(tempfile);

=head1 CONSTRUCTORS

=head2 new(filename => $path)

Creates a new C<AudioFile> instance.  C<filename> is required.

=cut

sub new ( $class, %args ) {
    croak 'filename is required' unless defined $args{filename};
    return bless {
        filename     => $args{filename},
        stream       => undef,
        SAMPLE_RATE  => undef,
        SAMPLE_WIDTH => undef,
        CHUNK        => 4096,
        DURATION     => undef,
        FRAME_COUNT  => undef,
        _tmp_files   => [],
    }, $class;
}

=head1 METHODS

=head2 open()

Opens the audio file and prepares the stream.  Must be called before passing
the source to C<Recognizer-E<gt>record>.  Returns C<$self> for chaining.

=cut

sub open ($self) {
    croak 'This audio source is already open'
        if defined $self->{stream};
    $self->_open_file( $self->{filename} );
    return $self;
}

=head2 close()

Closes the audio source and releases resources.

=cut

sub close ($self) {
    if ( defined $self->{stream} ) {
        $self->{stream}->close;
        $self->{stream}   = undef;
        $self->{DURATION} = undef;
    }
    # Remove temp files created while decoding compressed formats to WAV.
    for my $f ( @{ $self->{_tmp_files} } ) {
        unlink $f if -f $f;
    }
    $self->{_tmp_files} = [];
}

=head2 with($callback)

Opens the source, calls C<$callback->($self)>, then closes the source even if
an exception is thrown.  Returns the value returned by C<$callback>.

This is the idiomatic Perl equivalent of Python's C<with> statement.

=cut

sub with ( $self, $callback ) {
    $self->open;
    my $result = eval { $callback->($self) };
    my $err    = $@;
    $self->close;
    die $err if $err;
    return $result;
}

# Convenience accessors used by Recognizer
sub stream       ($self) { $self->{stream} }
sub SAMPLE_RATE  ($self) { $self->{SAMPLE_RATE} }
sub SAMPLE_WIDTH ($self) { $self->{SAMPLE_WIDTH} }
sub CHUNK        ($self) { $self->{CHUNK} }
sub DURATION     ($self) { $self->{DURATION} }
sub FRAME_COUNT  ($self) { $self->{FRAME_COUNT} }

# isa check for AudioSource duck-typing
sub isa_audio_source { 1 }

# ---------------------------------------------------------------------------
# Private: file parsing
# ---------------------------------------------------------------------------

sub _open_file ( $self, $filename ) {
    my $magic = _read_magic( $filename, 12 );

    # read() may return fewer than 12 bytes for short/truncated files.
    if ( defined $magic && length($magic) >= 12 ) {
        my ( $riff, undef, $wave ) = unpack( 'a4 V a4', $magic );
        if ( $riff eq 'RIFF' && $wave eq 'WAVE' ) {
            _try_open_wav( $self, $filename ) and return;
        }

        my ( $form, undef, $type ) = unpack( 'a4 N a4', $magic );
        if ( $form eq 'FORM' && ( $type eq 'AIFF' || $type eq 'AIFC' ) ) {
            _try_open_aiff( $self, $filename ) and return;
        }

        my $compressed_format = _detect_compressed_format($magic);
        if ( defined $compressed_format ) {
            _try_open_compressed( $self, $filename, $compressed_format ) and return;
        }
    }

    if ( _try_open_wav(  $self, $filename ) ) { return }
    if ( _try_open_aiff( $self, $filename ) ) { return }
    croak "Audio file could not be read as WAV, AIFF, FLAC, MP3, or M4A: $filename";
}

# --- WAV ---

sub _try_open_wav ( $self, $filename ) {
    CORE::open my $fh, '<', $filename or return 0;
    binmode $fh;

    my $header = '';
    read $fh, $header, 12;
    unless ( length($header) == 12 ) { CORE::close $fh; return 0 }

    my ( $riff, undef, $wave ) = unpack( 'a4 V a4', $header );
    unless ( $riff eq 'RIFF' && $wave eq 'WAVE' ) { CORE::close $fh; return 0 }

    my ( $rate, $sw, $nch, $data_start, $data_sz );

    while ( !eof $fh ) {
        my $ch = '';
        read $fh, $ch, 8;
        last unless length($ch) == 8;
        my ( $id, $csz ) = unpack( 'a4 V', $ch );

        if ( $id eq 'fmt ' ) {
            my $fmt = '';
            read $fh, $fmt, $csz;
            my ( $fmt_tag, $nc, $sr ) = unpack( 'v v V', $fmt );
            unless ( $fmt_tag == 1 || $fmt_tag == 3 ) {    # PCM or IEEE float
                CORE::close $fh;
                croak "Only PCM WAV files are supported (format tag: $fmt_tag)";
            }
            my $bps = unpack( 'v', substr( $fmt, 14, 2 ) );
            $nch = $nc;
            $rate = $sr;
            $sw   = int( $bps / 8 );
        }
        elsif ( $id eq 'data' ) {
            $data_start = tell $fh;
            $data_sz    = $csz;
            last;
        }
        else {
            # Chunks must be padded to even byte boundaries
            my $skip = $csz + ( $csz % 2 );
            seek $fh, $skip, 1;
        }
    }

    unless ( defined $data_start && defined $rate && defined $sw ) {
        CORE::close $fh;
        return 0;
    }

    seek $fh, $data_start, 0;
    my $pcm = '';
    read $fh, $pcm, $data_sz;
    CORE::close $fh;

    $pcm = _stereo_to_mono( $pcm, $sw ) if $nch && $nch == 2;

    $self->_set_audio( $pcm, $rate, $sw );
    return 1;
}

# --- AIFF ---

sub _try_open_aiff ( $self, $filename ) {
    CORE::open my $fh, '<', $filename or return 0;
    binmode $fh;

    my $header = '';
    read $fh, $header, 12;
    unless ( length($header) == 12 ) { CORE::close $fh; return 0 }

    my ( $form, undef, $type ) = unpack( 'a4 N a4', $header );
    unless ( $form eq 'FORM' && ( $type eq 'AIFF' || $type eq 'AIFC' ) ) {
        CORE::close $fh;
        return 0;
    }

    my ( $rate, $sw, $nch, $nframes, $pcm_data );

    while ( !eof $fh ) {
        my $ch = '';
        read $fh, $ch, 8;
        last unless length($ch) == 8;
        my ( $id, $csz ) = unpack( 'a4 N', $ch );

        if ( $id eq 'COMM' ) {
            my $comm = '';
            read $fh, $comm, $csz;
            ( $nch, $nframes ) = unpack( 'n N', $comm );
            my $bps = unpack( 'n', substr( $comm, 6, 2 ) );
            $sw   = int( $bps / 8 );
            $rate = int( _decode_80bit_float( substr( $comm, 8, 10 ) ) );
        }
        elsif ( $id eq 'SSND' ) {
            my $meta = '';
            read $fh, $meta, 8;    # skip offset and blockSize
            my $audio_sz = $csz - 8;
            read $fh, $pcm_data, $audio_sz;
            last;
        }
        else {
            my $skip = $csz + ( $csz % 2 );
            seek $fh, $skip, 1;
        }
    }
    CORE::close $fh;

    return 0 unless defined $pcm_data && defined $rate && defined $sw;

    # AIFF is big-endian; convert to little-endian
    require Speech::Recognition::AudioData;
    $pcm_data = Speech::Recognition::AudioData::_byteswap( $pcm_data, $sw );
    $pcm_data = _stereo_to_mono( $pcm_data, $sw ) if $nch && $nch == 2;

    $self->_set_audio( $pcm_data, $rate, $sw );
    return 1;
}

sub _read_magic ( $filename, $nbytes ) {
    CORE::open my $fh, '<', $filename or return undef;
    binmode $fh;
    my $magic = '';
    read $fh, $magic, $nbytes;
    CORE::close $fh;
    return $magic;
}

sub _detect_compressed_format ($magic) {
    return 'flac' if length($magic) >= 4 && substr( $magic, 0, 4 ) eq 'fLaC';

    # MP3 starts with ID3v2 or MPEG sync bytes.
    my $mp3_head = substr( $magic, 0, 3 );
    my $is_id3   = ( $mp3_head eq 'ID3' );
    my $is_sync  = ( substr( $mp3_head, 0, 2 ) =~ /\A\xff[\xfb\xf3\xf2]\z/ );
    return 'mp3' if $is_id3 || $is_sync;

    # M4A/MP4 uses 'ftyp' in the ISO Base Media box header.
    return 'm4a' if length($magic) >= 8 && substr( $magic, 4, 4 ) eq 'ftyp';
    return undef;
}

sub _try_open_compressed ( $self, $filename, $format ) {
    require Speech::Recognition::Recognizer::_Base;

    my @cmd;
    my $decoder;
    my $decode_failed_msg;
    my $decoded_wav_failed_msg;

    # Standard ffmpeg flags for all formats (16kHz mono WAV output)
    my @ffmpeg_flags = ( '-y', '-i', $filename,
        '-ar', '16000', '-ac', '1', '-f', 'wav', '__OUT__' );

    if ( $format eq 'flac' ) {
        # Try native flac tool first; fall back to ffmpeg if unavailable
        $decoder = Speech::Recognition::Recognizer::_Base::which('flac');
        if ( defined $decoder ) {
            @cmd = ( $decoder, '--decode', '--silent', '__OUT__', '--force', $filename );
        }
        else {
            $decoder = Speech::Recognition::Recognizer::_Base::which('ffmpeg');
            croak 'FLAC decoding requires flac or ffmpeg on PATH' unless defined $decoder;
            @cmd = ( $decoder, @ffmpeg_flags );
        }
        $decode_failed_msg = "FLAC decoder failed for '$filename' (exit \$?)";
        $decoded_wav_failed_msg = "Could not read FLAC-decoded WAV from '__TMP_WAV__'";
    }
    elsif ( $format eq 'mp3' ) {
        $decoder = Speech::Recognition::Recognizer::_Base::which('ffmpeg')
                // Speech::Recognition::Recognizer::_Base::which('mpg123');
        croak 'MP3 decoding requires ffmpeg or mpg123 on PATH' unless defined $decoder;

        my $is_ffmpeg = ( $decoder =~ m{(?:^|/)ffmpeg\z} );
        @cmd = $is_ffmpeg
            ? ( $decoder, @ffmpeg_flags )
            : ( $decoder, '--quiet', '--wav', '__OUT__', $filename );
        $decode_failed_msg = "MP3 decoder failed for '$filename' (exit \$?)";
        $decoded_wav_failed_msg = "Could not read MP3-decoded WAV from '__TMP_WAV__'";
    }
    elsif ( $format eq 'm4a' ) {
        $decoder = Speech::Recognition::Recognizer::_Base::which('ffmpeg');
        croak 'M4A/MP4 decoding requires ffmpeg on PATH' unless defined $decoder;

        @cmd = ( $decoder, @ffmpeg_flags );
        $decode_failed_msg = "ffmpeg failed for '$filename' (exit \$?)";
        $decoded_wav_failed_msg = 'Could not read M4A/MP4-decoded WAV';
    }
    else {
        return 0;
    }

    my ( $tmp_fh, $tmp_wav ) = tempfile( SUFFIX => '.wav', UNLINK => 0 );
    CORE::close $tmp_fh;
    push @{ $self->{_tmp_files} }, $tmp_wav;

    for my $arg (@cmd) {
        if ( $arg eq '__OUT__' ) {
            if ( $format eq 'flac' && $decoder =~ m{(?:^|/)flac\z} ) {
                $arg = "--output-name=$tmp_wav";
            }
            else {
                $arg = $tmp_wav;
            }
        }
    }

    system(@cmd) == 0
        or croak $decode_failed_msg;

    my $ok = _try_open_wav( $self, $tmp_wav );
    if ( !$ok ) {
        my $msg = $decoded_wav_failed_msg;
        $msg =~ s/__TMP_WAV__/$tmp_wav/g;
        croak $msg;
    }
    return 1;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _set_audio ( $self, $pcm, $rate, $sw ) {
    croak "sample_width must be 1-4" unless $sw >= 1 && $sw <= 4;
    $self->{SAMPLE_RATE}  = $rate;
    $self->{SAMPLE_WIDTH} = $sw;
    $self->{FRAME_COUNT}  = int( length($pcm) / $sw );
    $self->{DURATION}     = $self->{FRAME_COUNT} / $rate;
    $self->{stream}       = Speech::Recognition::AudioFile::Stream->new( $pcm, $sw );
}

# Decode a 10-byte 80-bit extended float (AIFF sample rate field, big-endian).
sub _decode_80bit_float ($bytes) {
    my @b  = unpack( 'C10', $bytes );
    my $exp = ( ( $b[0] & 0x7F ) << 8 ) | $b[1];
    $exp -= 16383;    # unbias
    my $mantissa = 0;
    $mantissa = $mantissa * 256 + $b[$_] for 2 .. 9;
    return $mantissa * 2**( $exp - 63 );
}

sub _stereo_to_mono ( $data, $sw ) {
    my $fmt  = $sw == 1 ? 'C*' : $sw == 2 ? 'v*' : 'V*';
    my @s    = unpack( $fmt, $data );
    my $half = 2**( $sw * 8 - 1 );
    my $mod  = 2**( $sw * 8 );
    my @mono;
    for ( my $i = 0 ; $i < @s ; $i += 2 ) {
        my $l = $s[$i]     >= $half ? $s[$i]     - $mod : $s[$i];
        my $r = $s[ $i + 1 ] >= $half ? $s[ $i + 1 ] - $mod : $s[ $i + 1 ];
        my $m = int( ( $l + $r ) / 2 );
        push @mono, $m < 0 ? $m + $mod : $m;
    }
    return pack( $fmt, @mono );
}

1;

__END__

=head1 NOTES

=over 4

=item *

Only uncompressed PCM WAV files are supported.  Compressed WAV formats
(ADPCM, etc.) will cause an error.

=item *

FLAC decoding requires the C<flac> command to be on C<$PATH>.

=item *

Stereo audio is automatically downmixed to mono by averaging the two channels.

=back

=head1 AUTHOR

Perl port of the Python speech_recognition library by Anthony Zhang (Uberi).
The original Python library is available at L<https://github.com/Uberi/speech_recognition>.

=head1 LICENSE

Original Python code Copyright 2014-2026 Anthony Zhang (Uberi).
Perl port Copyright 2026 Timothy Butler.

BSD 3-Clause License. See L<https://opensource.org/licenses/BSD-3-Clause>.

=cut