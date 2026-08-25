ARG BASE_IMAGE=burnerpad:ci
FROM ${BASE_IMAGE}

USER root
RUN mkdir -p /cookie-layer-negative-control \
    && printf '%s\n' 'not-a-secret-regression-fixture' > /cookie-layer-negative-control/COOKIE
RUN rm /cookie-layer-negative-control/COOKIE
USER app
