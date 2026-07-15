(use-modules (guix inferior)
             (guix channels)
             (srfi srfi-1))

(define channels
  (list (channel
         (name 'guix)
         (url "https://git.savannah.gnu.org/git/guix.git")
         (commit
          "8e54584d4448d37ddf8ae995bb545a181ba2493c"))))

(define inferior
  (inferior-for-channels channels))

(packages->manifest
 (map (lambda (name)
        (first (lookup-inferior-packages inferior name)))
      '("ruby" "ffmpeg" "pulseaudio")))
