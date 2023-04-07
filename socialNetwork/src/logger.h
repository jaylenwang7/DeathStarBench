#ifndef SOCIAL_NETWORK_MICROSERVICES_LOGGER_H
#define SOCIAL_NETWORK_MICROSERVICES_LOGGER_H

#include <boost/log/expressions.hpp>
#include <boost/log/sinks.hpp>
#include <boost/log/sources/severity_logger.hpp>
#include <boost/log/trivial.hpp>
#include <boost/log/utility/setup/common_attributes.hpp>
#include <boost/log/utility/setup/console.hpp>
#include <boost/log/utility/setup/file.hpp>

#include <string.h>

namespace social_network {
#define __FILENAME__ \
    (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define LOG(severity) \
    BOOST_LOG_TRIVIAL(severity) << "(" << __FILENAME__ << ":" \
    << __LINE__ << ":" << __FUNCTION__ << ") "

void init_logger(const char* filename = nullptr,
                 boost::log::trivial::severity_level severity =
                     boost::log::trivial::info) {
    boost::log::register_simple_formatter_factory
        <boost::log::trivial::severity_level, char>("Severity");
    boost::log::add_common_attributes();

    if (filename) {
        boost::log::add_file_log(
            boost::log::keywords::file_name = filename,
            boost::log::keywords::format =
                "[%TimeStamp%] <%Severity%>: %Message%",
            boost::log::keywords::auto_flush = true
        );
    } else {
        boost::log::add_console_log(
            std::cerr, boost::log::keywords::format =
                "[%TimeStamp%] <%Severity%>: %Message%"
        );
    }

    boost::log::core::get()->set_filter(
        boost::log::trivial::severity >= severity
    );
}


} //namespace social_network

#endif //SOCIAL_NETWORK_MICROSERVICES_LOGGER_H
