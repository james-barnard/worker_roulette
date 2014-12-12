FROM ubuntu:14.04
MAINTAINER jwbarnard@comcast.net

ENV DEBIAN_FRONTEND noninteractive

USER root
RUN apt-get -qq -y update && \
  apt-get -qq -y upgrade && \
  apt-get -qq -y dist-upgrade && \
  dpkg-reconfigure tzdata && \
  dpkg-divert --local --rename --add /sbin/initctl && \
  ln -sf /bin/true /sbin/initctl && \
  dpkg-divert --local --rename --add /usr/bin/ischroot && \
  ln -sf /bin/true /usr/bin/ischroot && \
  apt-get -qq -y install -y lsof wget git unzip language-pack-en software-properties-common && \
  locale-gen en_US && \
  echo "LANG=en_US.UTF-8" > /etc/default/locale && \
  apt-get autoremove && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# install redis-server, postgresql
RUN apt-get -qq update && \
  apt-get -y -qq install postgresql postgresql-contrib git curl \
  nodejs npm libfreetype6-dev libfontconfig1-dev libreadline-dev \
  libxml2-dev libpq-dev && \
  /etc/init.d/postgresql start && \
  su - postgres -c "psql -c \"CREATE USER nexia WITH SUPERUSER CREATEDB PASSWORD 'Password1';\"" && \
  ln -s /usr/bin/nodejs /usr/local/bin/node && \
  npm install -g grunt-cli coffeelint

RUN apt-get update && \
  gpg --keyserver hkp://keys.gnupg.net --recv-keys D39DC0E3 && \
  apt-get install -y openssh-server openssh-client && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash nexia && \
  echo "nexia ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers && \
  chown -R nexia:nexia /usr/local

RUN add-apt-repository -y ppa:chris-lea/redis-server && \
  add-apt-repository -y ppa:brightbox/ruby-ng && \
  apt-get update && \
  apt-get -qq -y install redis-server ruby2.1 ruby2.1-dev && \
  apt-get clean
RUN chown -R redis:redis /var/lib/redis

RUN gem install bundler && bundle init

USER nexia
WORKDIR /home/nexia
RUN mkdir .ssh && \
  chmod 700 .ssh

ADD ssh/id_rsa_nexia /home/nexia/.ssh/id_rsa
ADD ssh/config /home/nexia/.ssh/config
ADD tune_kernel.sh /home/nexia/tune_kernel.sh

USER root
RUN chown -R nexia:nexia /home/nexia && \
  chmod 600 /home/nexia/.ssh/id_rsa
RUN chmod 755 /home/nexia/tune_kernel.sh && \
  chown nexia:nexia /home/nexia/tune_kernel.sh

USER nexia
WORKDIR /home/nexia
RUN git clone git@github.com:nexiahome/faceplate_proxy.git
RUN cd faceplate_proxy && bundle install --path vendor/bundle && \
  git config user.email "nexia@example.com" && \
  git config user.name "nexia"

RUN git clone git@github.com:nexiahome/conman.git
RUN cd conman && bundle install --path vendor/bundle && \
  git config user.email "nexia@example.com" && \
  git config user.name "nexia"

RUN git clone git@github.com:nexiahome/worker_roulette.git
RUN cd worker_roulette && bundle install --path vendor/bundle && \
  git config user.email "nexia@example.com" && \
  git config user.name "nexia"

RUN git clone git@github.com:james-barnard/worker_roulette.git nexia_worker_queues
RUN cd nexia_worker_queues && bundle install --path vendor/bundle && \
  git config user.email "nexia@example.com" && \
  git config user.name "nexia"

RUN git clone git@github.com:nexiahome/nexia_dealer.git
RUN cd nexia_dealer && bundle install --path vendor/bundle && \
  git config user.email "nexia@example.com" && \
  git config user.name "nexia"

USER root
ADD sysctl.conf /etc/sysctl.conf
ADD limits.conf /etc/security/limits.conf
ADD start.sh /home/nexia/start.sh
RUN chmod 755 /home/nexia/start.sh && \
  chown nexia:nexia /home/nexia/start.sh
EXPOSE 8092

USER nexia
WORKDIR /home/nexia
CMD ["/home/nexia/start.sh"]
