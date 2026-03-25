use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Speech::Recognition',
    AUTHOR           => 'Perl port of SpeechRecognition by Anthony Zhang (Uberi)',
    VERSION_FROM     => 'lib/Speech/Recognition.pm',
    ABSTRACT_FROM    => 'lib/Speech/Recognition.pm',
    LICENSE          => 'bsd',
    MIN_PERL_VERSION => '5.036',

    PREREQ_PM => {
        # Core modules (always available since the minimum Perl version)
        'Carp'         => 0,
        'POSIX'        => 0,
        'MIME::Base64' => '3.11',  # 3.11+ for encode/decode_base64url; core since Perl 5.6
        'Digest::SHA'  => 0,    # core since Perl 5.10
        'File::Temp'   => 0,    # core since Perl 5.6
        'IPC::Open3'   => 0,    # core since Perl 5.0
        'JSON::PP'     => 0,    # core since Perl 5.14

        # LWP is the standard HTTP client; ships with libwww-perl
        'LWP::UserAgent' => '6.00',
        'HTTP::Request'  => '6.00',
    },

    TEST_REQUIRES => {
        'Test::More'            => '1.00',
        'Test::LWP::UserAgent'  => '0',     # for t/20-backends-mock.t
    },

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/trbutler/speech_recognition.git',
                web  => 'https://github.com/trbutler/speech_recognition',
            },
            bugtracker => {
                web => 'https://github.com/trbutler/speech_recognition/issues',
            },
        },
        x_provides_scripts => {},
        # Optional run-time dependencies (loaded only by specific backends)
        optional_features => {
            google_cloud => {
                description => 'Google Cloud Speech-to-Text backend (GoogleCloud.pm)',
                prereqs     => { runtime => { requires => { 'Crypt::OpenSSL::RSA' => 0 } } },
            },
        },
        # Informational metadata for non-Perl runtime requirements.
        # CPAN prereqs cannot express external binaries, so these are kept
        # under x_* keys for discoverability by humans/tooling.
        x_external_programs => {
            audio_decoding => {
                required_for => [
                    'Speech::Recognition::AudioFile (compressed audio decode)',
                ],
                alternatives => [
                    {
                        program => 'ffmpeg',
                        supports_formats => [ 'mp3', 'm4a', 'mp4' ],
                    },
                    {
                        program => 'mpg123',
                        supports_formats => [ 'mp3' ],
                    },
                    {
                        program => 'flac',
                        supports_formats => [ 'flac' ],
                    },
                ],
            },
            local_speech_backends => {
                optional_for => [
                    'Speech::Recognition::Recognizer::Yap',
                    'Speech::Recognition::Recognizer::Whisper',
                ],
                alternatives => [
                    {
                        program => 'yap',
                        backend => 'recognize_yap',
                        platform => 'macOS',
                    },
                    {
                        program => 'whisper',
                        backend => 'recognize_whisper_local',
                        notes => 'openai-whisper CLI',
                    },
                    {
                        program => 'whisper-cpp',
                        backend => 'recognize_whisper_local',
                        notes => 'whisper.cpp CLI',
                    },
                ],
            },
        },
    },
);
