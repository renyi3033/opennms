/*******************************************************************************
 * This file is part of OpenNMS(R).
 *
 * Copyright (C) 2006-2012 The OpenNMS Group, Inc.
 * OpenNMS(R) is Copyright (C) 1999-2012 The OpenNMS Group, Inc.
 *
 * OpenNMS(R) is a registered trademark of The OpenNMS Group, Inc.
 *
 * OpenNMS(R) is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * OpenNMS(R) is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with OpenNMS(R).  If not, see:
 *      http://www.gnu.org/licenses/
 *
 * For more information contact:
 *     OpenNMS(R) Licensing <license@opennms.org>
 *     http://www.opennms.org/
 *     http://www.opennms.com/
 *******************************************************************************/

package org.opennms.netmgt.linkd;

import java.net.InetAddress;

import org.opennms.netmgt.model.topology.EndPoint;

public class AtInterface extends EndPoint {

    Integer m_nodeid;
    Integer m_ifIndex;
    public Integer getIfIndex() {
        return m_ifIndex;
    }
    public void setIfIndex(Integer ifIndex) {
        m_ifIndex = ifIndex;
    }



    String m_macAddress;
    InetAddress m_ipAddress;
    public Integer getNodeid() {
        return m_nodeid;
    }
    public void setNodeid(Integer nodeid) {
        m_nodeid = nodeid;
    }
    public String getMacAddress() {
        return m_macAddress;
    }
    public void setMacAddress(String macAddress) {
        m_macAddress = macAddress;
    }
    
    public InetAddress getIpAddress() {
        return m_ipAddress;
    }
    public void setIpAddress(InetAddress ipAddress) {
        m_ipAddress = ipAddress;
    }
    
    
    
    public AtInterface(Integer nodeid, String macAddress, InetAddress ipAddress) {
        super();
        m_nodeid = nodeid;
        m_macAddress = macAddress;
        m_ipAddress = ipAddress;
    }
    
    
}