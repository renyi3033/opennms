package org.opennms.features.gwt.graph.resource.list.client.presenter;

import java.util.ArrayList;
import java.util.List;

import org.opennms.features.gwt.graph.resource.list.client.presenter.KscGraphResourceListPresenter.SearchPopupDisplay;
import org.opennms.features.gwt.graph.resource.list.client.view.DefaultResourceListView;
import org.opennms.features.gwt.graph.resource.list.client.view.ResourceListItem;

import com.google.gwt.core.client.JsArray;
import com.google.gwt.event.dom.client.ClickEvent;
import com.google.gwt.event.dom.client.ClickHandler;
import com.google.gwt.event.dom.client.KeyCodes;
import com.google.gwt.event.dom.client.KeyPressEvent;
import com.google.gwt.event.dom.client.KeyPressHandler;
import com.google.gwt.user.client.Window.Location;
import com.google.gwt.user.client.ui.HasWidgets;

public class DefaultResourceListPresenter implements Presenter, DefaultResourceListView.Presenter<ResourceListItem> {
    
    private DefaultResourceListView<ResourceListItem> m_view;
    private SearchPopupDisplay m_searchPopup;
    private List<ResourceListItem> m_dataList;

    public DefaultResourceListPresenter(DefaultResourceListView<ResourceListItem> view, SearchPopupDisplay searchPopup, JsArray<ResourceListItem> dataList) {
        m_view = view;
        m_view.setPresenter(this);
        
        initializeSearchPopup(searchPopup);
        
        m_dataList = convertJsArrayToList(dataList);
        m_view.setDataList(m_dataList);
    }
    
    private List<ResourceListItem> convertJsArrayToList(JsArray<ResourceListItem> resourceList) {
        List<ResourceListItem> data = new ArrayList<ResourceListItem>();
        for(int i = 0; i < resourceList.length(); i++) {
            data.add(resourceList.get(i));
        }
        return data;
    }
    
    private void initializeSearchPopup(SearchPopupDisplay searchPopupView) {
        m_searchPopup = searchPopupView;
        m_searchPopup.setTargetWidget(m_view.asWidget());
        m_searchPopup.getSearchConfirmBtn().addClickHandler(new ClickHandler() {

            @Override
            public void onClick(ClickEvent event) {
                m_searchPopup.hideSearchPopup();
                m_view.setDataList(filterList(m_searchPopup.getSearchText()));
            }
        });
        
        m_searchPopup.getCancelBtn().addClickHandler(new ClickHandler() {

            @Override
            public void onClick(ClickEvent event) {
                m_searchPopup.hideSearchPopup();
            }
        });
        
        m_searchPopup.getTextBox().addKeyPressHandler(new KeyPressHandler() {
            
            @Override
            public void onKeyPress(KeyPressEvent event) {
                if(event.getCharCode() == KeyCodes.KEY_ENTER) {
                    m_searchPopup.hideSearchPopup();
                    m_view.setDataList(filterList(m_searchPopup.getSearchText()));
                }
            }
        });
    }
    
    private List<ResourceListItem> filterList(String searchText) {
        List<ResourceListItem> list = new ArrayList<ResourceListItem>();
        for(ResourceListItem item : m_dataList) {
            if(item.getValue().contains(searchText)) {
                list.add(item);
            }
        }
        return list;
    }
    
    @Override
    public void go(HasWidgets container) {
        container.clear();
        container.add(m_view.asWidget());
    }

    @Override
    public void onResourceItemSelected() {
        Location.assign("graph/chooseresource.htm?reports=all&parentResourceId=" + m_view.getSelectedResource().getId());
    }

    @Override
    public void onSearchButtonClicked() {
        m_searchPopup.showSearchPopup();
    }

    

}
