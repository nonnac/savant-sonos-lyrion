# Lyrion Music Server + Savant compatibility patches + Savant Sonos Bridge plugin.
ARG LMS_TAG=stable
FROM ghcr.io/lms-community/lyrionmusicserver:${LMS_TAG}

USER root
COPY docker/apply-patches.sh /tmp/apply-patches.sh
COPY lyrion-plugin/SavantSonos /tmp/SavantSonos
RUN sh /tmp/apply-patches.sh && rm -rf /tmp/apply-patches.sh /tmp/SavantSonos

LABEL org.opencontainers.image.title="savant-sonos-lyrion" \
      org.opencontainers.image.description="Lyrion Music Server patched for Savant (Squeezebox browse) plus Sonos soundbar control for Savant" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"
