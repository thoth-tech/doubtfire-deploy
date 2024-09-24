FROM texlive/texlive:latest

RUN apt-get update \
    && apt-get install -y \
    imagemagick \
    inkscape \
    librsvg2-bin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY ./doubtfire-api/lib/shell/latex_build.sh /texlive/shell/latex_build.sh
RUN chmod +x /texlive/shell/latex_build.sh

CMD ["sh", "-c", "while sleep 5000; do :; done"]
