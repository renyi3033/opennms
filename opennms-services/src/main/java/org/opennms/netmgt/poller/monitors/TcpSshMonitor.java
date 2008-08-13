//
// This file is part of the OpenNMS(R) Application.
//
// OpenNMS(R) is Copyright (C) 2002-2003 The OpenNMS Group, Inc. All rights reserved.
// OpenNMS(R) is a derivative work, containing both original code, included code and modified
// code that was published under the GNU General Public License. Copyrights for modified
// and included code are below.
//
// OpenNMS(R) is a registered trademark of The OpenNMS Group, Inc.
//
// Modifications:
//
// 2004 May 05: Switch from SocketChannel to Socket with connection timeout.
// 2003 Jul 21: Explicitly closed socket.
// 2003 Jul 18: Enabled retries for monitors.
// 2003 Jun 11: Added a "catch" for RRD update errors. Bug #748.
// 2003 Apr 24: Added new SSH poller, based on the generic TCP poller.
//
// Original code base Copyright (C) 1999-2001 Oculan Corp. All rights reserved.
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
//
// For more information contact:
//      OpenNMS Licensing <license@opennms.org>
//      http://www.opennms.org/
//      http://www.opennms.com/
//

package org.opennms.netmgt.poller.monitors;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.InterruptedIOException;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NoRouteToHostException;
import java.net.Socket;
import java.util.Map;

import org.apache.log4j.Level;
import org.opennms.netmgt.model.PollStatus;
import org.opennms.netmgt.poller.Distributable;
import org.opennms.netmgt.poller.MonitoredService;
import org.opennms.netmgt.poller.NetworkInterface;
import org.opennms.netmgt.poller.NetworkInterfaceNotSupportedException;
import org.opennms.netmgt.utils.ParameterMap;

/**
 * This class is designed to be used by the service poller framework to test the
 * availability of a generic TCP service on remote interfaces. The class
 * implements the ServiceMonitor interface that allows it to be used along with
 * other plug-ins by the service poller framework.
 * 
 * @author <A HREF="mailto:tarus@opennms.org">Tarus Balog</A>
 * @author <A HREF="mike@opennms.org">Mike</A>
 * @author Weave
 * @author <A HREF="http://www.opennms.org/">OpenNMS </A>
 * 
 */

@Distributable
final public class TcpSshMonitor extends IPv4Monitor {

    /**
     * Default port.
     */
    private static final int DEFAULT_PORT = -1;

    /**
     * Default retries.
     */
    private static final int DEFAULT_RETRY = 0;

    /**
     * Default timeout. Specifies how long (in milliseconds) to block waiting
     * for data from the monitored interface.
     */
    private static final int DEFAULT_TIMEOUT = 3000; // 3 second timeout on read()

    /**
     * Poll the specified address for service availability.
     * 
     * During the poll an attempt is made to connect on the specified port. If
     * the connection request is successful, the banner line generated by the
     * interface is parsed and if the banner text indicates that we are talking
     * to Provided that the interface's response is valid we set the service
     * status to SERVICE_AVAILABLE and return.
     * @param parameters
     *            The package parameters (timeout, retry, etc...) to be used for
     *            this poll.
     * @param iface
     *            The network interface to test the service on.
     * @return The availability of the interface and if a transition event
     *         should be suppressed.
     * 
     * @throws java.lang.RuntimeException
     *             Thrown if the interface experiences errors during the poll.
     */
    @SuppressWarnings("unchecked")
    public PollStatus poll(MonitoredService svc, Map parameters) {
        NetworkInterface iface = svc.getNetInterface();

        //
        // Get interface address from NetworkInterface
        //
        if (iface.getType() != NetworkInterface.TYPE_IPV4)
            throw new NetworkInterfaceNotSupportedException("Unsupported interface type, only TYPE_IPV4 currently supported");

        TimeoutTracker tracker = new TimeoutTracker(parameters, DEFAULT_RETRY, DEFAULT_TIMEOUT);

        // Port
        //
        int port = ParameterMap.getKeyedInteger(parameters, "port", DEFAULT_PORT);
        if (port == DEFAULT_PORT) {
            throw new RuntimeException("SshMonitor: required parameter 'port' is not present in supplied properties.");
        }

        // BannerMatch
        //
        String strBannerMatch = (String) parameters.get("banner");

        // Get the address instance.
        //
        InetAddress ipv4Addr = (InetAddress) iface.getAddress();

        if (log().isDebugEnabled())
            log().debug("poll: address = " + ipv4Addr.getHostAddress() + ", port = " + port + ", " + tracker);

        // Give it a whirl
        //
        PollStatus serviceStatus = PollStatus.unavailable();

        for (tracker.reset(); tracker.shouldRetry() && !serviceStatus.isAvailable(); tracker.nextAttempt()) {
            Socket socket = null;
            try {
                //
                // create a connected socket
                //
                tracker.startAttempt();

                socket = new Socket();
                socket.connect(new InetSocketAddress(ipv4Addr, port), tracker.getConnectionTimeout());
                socket.setSoTimeout(tracker.getSoTimeout());
                log().debug("SshMonitor: connected to host: " + ipv4Addr + " on port: " + port);

                // We're connected, so upgrade status to unresponsive
                serviceStatus = PollStatus.unresponsive();

                if (strBannerMatch == null || strBannerMatch.equals("*")) {
                    serviceStatus = PollStatus.available(tracker.elapsedTimeInMillis());
                    break;
                }

                BufferedReader rdr = new BufferedReader(new InputStreamReader(socket.getInputStream()));

                //
                // Tokenize the Banner Line, and check the first
                // line for a valid return.
                //
                String response = rdr.readLine();
                double responseTime = tracker.elapsedTimeInMillis();

                if (response == null)
                    continue;
                if (log().isDebugEnabled()) {
                    log().debug("poll: banner = " + response);
                    log().debug("poll: responseTime= " + responseTime + "ms");
                }

                if (response.indexOf(strBannerMatch) > -1) {
                    serviceStatus = PollStatus.available(responseTime);
                    // send the identifier string
                    //
                    String cmd = "SSH-1.99-OpenNMS_1.1\r\n";
                    socket.getOutputStream().write(cmd.getBytes());
                    // get the response code.
                    //
                    response = null;
                    try {
                        response = rdr.readLine();
                    } catch (IOException e) {
                    }

                } else
                    serviceStatus = PollStatus.unavailable();
            } catch (NoRouteToHostException e) {
            	serviceStatus = logDown(Level.WARN, "No route to host exception for address " + ipv4Addr.getHostAddress(), e);
                break; // Break out of for(;;)
            } catch (InterruptedIOException e) {
            	serviceStatus = logDown(Level.DEBUG, "did not connect to host with " + tracker);
            } catch (ConnectException e) {
            	serviceStatus = logDown(Level.DEBUG, "Connection exception for address: " + ipv4Addr, e);
            } catch (IOException e) {
            	serviceStatus = logDown(Level.DEBUG, "IOException while polling address: " + ipv4Addr, e);
            } finally {
                try {
                    // Close the socket
                    if (socket != null)
                        socket.close();
                } catch (IOException e) {
                    e.fillInStackTrace();
                    if (log().isDebugEnabled())
                        log().debug("poll: Error closing socket.", e);
                }
            }
        }

        //
        // return the status of the service
        //
        return serviceStatus;
    }

}
