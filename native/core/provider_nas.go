package core

import (
	"context"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type nasSettings struct {
	BaseURL  string
	Root     string
	User     string
	Password string
}

var (
	nasSettingsMu     sync.RWMutex
	nasSettingsActive nasSettings
	nasHTTPClient     = &http.Client{Timeout: 25 * time.Second}
)

func setNasSettings(settings nasSettings) {
	nasSettingsMu.Lock()
	nasSettingsActive = settings
	nasSettingsMu.Unlock()
}

func currentNasSettings() (nasSettings, error) {
	nasSettingsMu.RLock()
	settings := nasSettingsActive
	nasSettingsMu.RUnlock()
	settings.BaseURL = strings.TrimRight(strings.TrimSpace(settings.BaseURL), "/")
	settings.Root = strings.Trim(strings.TrimSpace(settings.Root), "/")
	if settings.BaseURL == "" {
		return nasSettings{}, errors.New("请先在设置中配置 NAS 地址")
	}
	return settings, nil
}

var nasDescriptor = SourceDescriptor{
	ID: "nas", Name: "NAS", Description: "本地 NAS 媒体库",
	Group: "local", GroupName: "本地", EntryName: "NAS",
	AllowEmptyCatalog:  true,
	ValidCategory:      func(category string) bool { return category == "all" },
}

func init() {
	Register(nasDescriptor, func(host Host) Provider { return &nasProvider{host: host} })
}

type nasProvider struct {
	host Host
}

func (p *nasProvider) Descriptor() SourceDescriptor { return nasDescriptor }

func (p *nasProvider) Categories(ctx context.Context, force bool) ([]Category, error) {
	return []Category{{ID: "all", Name: "全部"}}, nil
}

func (p *nasProvider) CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	if page > 1 {
		return nil, false, nil
	}
	settings, err := currentNasSettings()
	if err != nil {
		return nil, false, err
	}
	entries, err := nasList(ctx, settings, "")
	if err != nil {
		return nil, false, err
	}
	items := make([]Drama, 0, len(entries))
	for _, entry := range entries {
		if !entry.directory {
			continue
		}
		items = append(items, Drama{
			ID: ProviderDramaID("nas", entry.name), Source: "nas", SourceID: entry.name,
			Title: entry.name, Name: entry.name, Category: "all",
			Cover: nasFileURL(settings, path.Join(entry.name, "poster.jpg")),
		})
	}
	return items, false, nil
}

func (p *nasProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	settings, err := currentNasSettings()
	if err != nil {
		return Drama{}, nil, err
	}
	sourceID = strings.Trim(strings.TrimSpace(sourceID), "/")
	if sourceID == "" || strings.Contains(sourceID, "..") {
		return Drama{}, nil, errors.New("NAS 剧集信息无效")
	}
	season := path.Join(sourceID, "Season 01")
	entries, err := nasList(ctx, settings, season)
	if err != nil {
		season = sourceID
		entries, err = nasList(ctx, settings, sourceID)
	}
	if err != nil {
		return Drama{}, nil, err
	}
	videos := nasVideos(entries)
	chapters := make([]Chapter, 0, len(videos))
	for _, entry := range videos {
		chapters = append(chapters, Chapter{
			ID:        ProviderChapterID("nas", sourceID, entry.name),
			Source:    "nas",
			Title:     strings.TrimSuffix(entry.name, path.Ext(entry.name)),
			VideoURL:  nasFileURL(settings, path.Join(season, entry.name)),
			MediaType: "video/mp4",
			MediaSize: entry.size,
		})
	}
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("该剧暂时没有可播放的分集")
	}
	nfo := nasFetchNfo(ctx, settings, sourceID)
	title := sourceID
	if value := strings.TrimSpace(nfo.Title); value != "" {
		title = value
	}
	category := "all"
	if value := strings.TrimSpace(nfo.Genre); value != "" {
		category = value
	}
	drama := Drama{
		ID: ProviderDramaID("nas", sourceID), Source: "nas", SourceID: sourceID,
		Title: title, Name: title, Category: category,
		Desc:         strings.TrimSpace(nfo.Plot),
		Score:        strings.TrimSpace(nfo.Rating),
		Cover:        nasFileURL(settings, path.Join(sourceID, "poster.jpg")),
		TotalEpisode: strconv.Itoa(len(chapters)),
	}
	tags := append([]string{}, nfo.Tags...)
	size := strings.TrimSpace(nfo.Size)
	badge := "共 " + strconv.Itoa(len(chapters)) + " 集"
	if size != "" {
		badge += " · " + size
	}
	if value := strings.TrimSpace(nfo.Source); value != "" {
		badge += "\n" + value
	}
	drama.Tags = tags
	drama.Badge = badge
	return drama, chapters, nil
}

func (p *nasProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	settings, err := currentNasSettings()
	if err != nil {
		return ProviderMedia{}, err
	}
	address := strings.TrimSpace(task.Chapter.VideoURL)
	if address == "" {
		return ProviderMedia{}, errors.New("NAS 文件地址缺失")
	}
	return ProviderMedia{
		URL:     address,
		Headers: map[string]string{"Authorization": nasAuthorization(settings)},
	}, nil
}

func nasAuthorization(settings nasSettings) string {
	return "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(settings.User+":"+settings.Password),
	)
}

func nasFileURL(settings nasSettings, relative string) string {
	target := strings.TrimRight(settings.BaseURL, "/")
	if settings.Root != "" {
		target += "/" + strings.Trim(settings.Root, "/")
	}
	for _, segment := range strings.Split(relative, "/") {
		if segment == "" {
			continue
		}
		target += "/" + url.PathEscape(segment)
	}
	return target
}

type nasEntry struct {
	name      string
	path      string
	directory bool
	size      int64
}

type nasMultiStatus struct {
	Responses []nasStatusResponse `xml:"response"`
}

type nasStatusResponse struct {
	Href      string `xml:"href"`
	PropStats []struct {
		Prop struct {
			ResourceType struct {
				Collection []struct{} `xml:"collection"`
			} `xml:"resourcetype"`
			ContentLength string `xml:"getcontentlength"`
		} `xml:"prop"`
	} `xml:"propstat"`
}

func nasList(ctx context.Context, settings nasSettings, relative string) ([]nasEntry, error) {
	request, err := http.NewRequestWithContext(
		ctx, "PROPFIND", nasFileURL(settings, relative), nil,
	)
	if err != nil {
		return nil, errors.New("NAS 目录地址无效")
	}
	request.SetBasicAuth(settings.User, settings.Password)
	request.Header.Set("Depth", "1")
	request.Header.Set("Content-Type", "application/xml")
	response, err := nasHTTPClient.Do(request)
	if err != nil {
		return nil, errors.New("无法连接 NAS，请检查地址和网络")
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusMultiStatus, http.StatusOK:
	case http.StatusUnauthorized:
		return nil, errors.New("NAS 用户名或密码不正确")
	case http.StatusNotFound:
		return nil, errors.New("NAS 目录不存在")
	case http.StatusForbidden:
		return nil, errors.New("没有访问该目录的权限")
	default:
		return nil, fmt.Errorf("NAS 返回 HTTP %d", response.StatusCode)
	}
	var status nasMultiStatus
	if err := xml.NewDecoder(response.Body).Decode(&status); err != nil {
		return nil, errors.New("无法解析 NAS 目录")
	}
	base := strings.Trim(relative, "/")
	entries := make([]nasEntry, 0, len(status.Responses))
	seen := map[string]bool{}
	for _, row := range status.Responses {
		value := nasRelativeHref(row.Href, settings.Root)
		if value == "" || value == base || seen[value] {
			continue
		}
		name := value[strings.LastIndex(value, "/")+1:]
		if name == "" || strings.HasPrefix(name, ".") {
			continue
		}
		seen[value] = true
		directory := false
		size := int64(0)
		for _, propstat := range row.PropStats {
			if len(propstat.Prop.ResourceType.Collection) > 0 {
				directory = true
			}
			if propstat.Prop.ContentLength != "" {
				if parsed, err := strconv.ParseInt(propstat.Prop.ContentLength, 10, 64); err == nil {
					size = parsed
				}
			}
		}
		entries = append(entries, nasEntry{name: name, path: value, directory: directory, size: size})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].directory != entries[j].directory {
			return entries[i].directory
		}
		return strings.ToLower(entries[i].name) < strings.ToLower(entries[j].name)
	})
	return entries, nil
}

func nasRelativeHref(href, root string) string {
	parsed, err := url.Parse(strings.TrimSpace(href))
	if err != nil {
		return ""
	}
	value := parsed.Path
	if decoded, err := url.PathUnescape(value); err == nil {
		value = decoded
	}
	value = strings.Trim(value, "/")
	root = strings.Trim(root, "/")
	if root != "" && strings.HasPrefix(value, root) {
		value = strings.Trim(strings.TrimPrefix(value, root), "/")
	}
	return value
}

type nasShowNfo struct {
	Title        string   `xml:"title"`
	Plot         string   `xml:"plot"`
	Genre        string   `xml:"genre"`
	Rating       string   `xml:"rating"`
	Tags         []string `xml:"tag"`
	EpisodeCount string   `xml:"episodecount"`
	Size         string   `xml:"size"`
	Source       string   `xml:"source"`
}

func nasFetchNfo(ctx context.Context, settings nasSettings, sourceID string) nasShowNfo {
	request, err := http.NewRequestWithContext(
		ctx, "GET", nasFileURL(settings, path.Join(sourceID, "tvshow.nfo")), nil,
	)
	if err != nil {
		return nasShowNfo{}
	}
	request.SetBasicAuth(settings.User, settings.Password)
	response, err := nasHTTPClient.Do(request)
	if err != nil {
		return nasShowNfo{}
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nasShowNfo{}
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nasShowNfo{}
	}
	var nfo nasShowNfo
	if err := xml.Unmarshal(body, &nfo); err != nil {
		return nasShowNfo{}
	}
	return nfo
}

func nasVideos(entries []nasEntry) []nasEntry {
	videos := make([]nasEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.directory {
			continue
		}
		switch strings.ToLower(path.Ext(entry.name)) {
		case ".mp4", ".mkv", ".m4v", ".ts", ".webm", ".mov":
			videos = append(videos, entry)
		}
	}
	return videos
}
